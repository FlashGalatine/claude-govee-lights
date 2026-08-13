using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    /// <summary>
    /// Renders frames to stdout and exits, touching no hardware and binding no port.
    ///
    /// This exists because Effects is pure and deterministic but the project has no
    /// unit-test project - net48 plus a hardware dependency makes one disproportionate.
    /// Dumping frames lets Test-Repo.ps1 assert on real render output in CI, and lets a
    /// human eyeball a new effect with the lights off.
    /// </summary>
    public static class FrameDump
    {
        public static int Run(string[] args)
        {
            // Dump mode returns before Log.Init, so warnings had nowhere to go: a
            // --style with a typo in it printed a perfectly clean solid frame stream and
            // said nothing, while the docs point users here to preview a style AND tell
            // them typos announce themselves in the log. Route them to stderr rather than
            // a file - there is no config dir in this mode - and to stderr rather than
            // stdout so the frame stream stays machine-readable.
            Log.AlsoConsole = true;
            Log.ConsoleToStderr = true;

            if (HasFlag(args, "--list-known")) return ListKnown();
            if (HasFlag(args, "--resolve-states")) return ResolveStates(args);
            if (HasFlag(args, "--splice-states")) return SpliceStates(args);
            if (HasFlag(args, "--list-themes")) return ListThemes();
            if (HasFlag(args, "--check-theme-name"))
            {
                var n = Arg(args, "--check-theme-name", null);
                Console.Out.WriteLine(Themes.IsValidName(n) ? "valid" : "invalid");
                Console.Out.Flush();
                return 0;
            }

            var segments = ArgInt(args, "--segments", 10);
            var seconds  = ArgDouble(args, "--seconds", 2.0);
            var fps      = ArgInt(args, "--fps", 25);
            var stateName = Arg(args, "--state", null);
            var styleJson = Arg(args, "--style", null);

            if (fps < 1) fps = 1;
            if (segments < 1) segments = 1;

            ResolvedStyle style;
            if (!string.IsNullOrEmpty(styleJson))
            {
                StateStyle raw;
                try { raw = new JavaScriptSerializer().Deserialize<StateStyle>(styleJson); }
                catch (Exception ex) { Console.Error.WriteLine("bad --style: " + ex.Message); return 2; }
                if (raw == null) { Console.Error.WriteLine("bad --style: null"); return 2; }
                style = Palette.ResolveStyleFor(segments, raw);
            }
            else
            {
                Activity a;
                if (!Enum.TryParse(stateName ?? "Thinking", true, out a))
                {
                    Console.Error.WriteLine("unknown --state: " + stateName);
                    return 2;
                }
                DaemonConfig cfg = null;
                var configPath = Arg(args, "--config", null);
                if (!string.IsNullOrEmpty(configPath))
                {
                    string e;
                    cfg = DaemonConfig.Load(configPath, out e);
                    if (cfg == null) { Console.Error.WriteLine("bad --config: " + e); return 2; }
                }
                DeviceConfig dev = null;
                var deviceName = Arg(args, "--device", null);
                if (cfg != null && !string.IsNullOrEmpty(deviceName))
                {
                    dev = cfg.Devices.FirstOrDefault(x => x != null &&
                        string.Equals(x.Name, deviceName, StringComparison.OrdinalIgnoreCase));

                    // A typo here used to return the global-layer style with exit 0, so the
                    // documented way to preview per-device overrides silently showed the
                    // wrong answer. Every other bad argument reports and returns 2.
                    if (dev == null)
                    {
                        Console.Error.WriteLine("unknown --device: " + deviceName +
                            " (known: " + string.Join(", ", cfg.Devices.Where(x => x != null).Select(x => x.Name).ToArray()) + ")");
                        return 2;
                    }
                }
                style = Palette.ResolveFor(cfg, null, dev, a, segments);
            }

            ResolvedStyle fromStyle = null;
            var fromName = Arg(args, "--from", null);
            if (!string.IsNullOrEmpty(fromName))
            {
                Activity fa;
                if (!Enum.TryParse(fromName, true, out fa))
                {
                    Console.Error.WriteLine("unknown --from: " + fromName);
                    return 2;
                }
                fromStyle = Palette.ResolveFor(null, null, null, fa, segments);
            }

            var w = Console.Out;
            w.WriteLine("# effect=" + style.Effect +
                        " hz=" + style.Hz.ToString("0.###", CultureInfo.InvariantCulture) +
                        " color=" + style.Color.ToHex() +
                        " color2=" + (style.HasColor2 ? style.Color2.ToHex() : "none") +
                        " dir=" + style.Direction + " ease=" + style.Easing +
                        " tail=" + style.Tail.ToString("0.###", CultureInfo.InvariantCulture) +
                        " depth=" + style.Depth.ToString("0.###", CultureInfo.InvariantCulture) +
                        " segments=" + segments + " fps=" + fps);

            var frames = (int)Math.Round(seconds * fps);
            for (int i = 0; i < frames; i++)
            {
                var t = (double)i / fps;
                var f = Effects.Render(style, t, t, segments);
                if (fromStyle != null)
                {
                    // Sweep mix 0 -> 1 across the requested duration.
                    var mix = frames <= 1 ? 1.0 : (double)i / (frames - 1);
                    f = Effects.Blend(Effects.Render(fromStyle, t, t, segments), f, mix);
                }
                var cells = f.Segments ?? new[] { f.Solid };
                w.WriteLine(t.ToString("0.000", CultureInfo.InvariantCulture) + "," +
                            string.Join(",", cells.Select(c => c.ToHex()).ToArray()));
            }
            w.Flush();
            return 0;
        }

        static bool HasFlag(string[] args, string name)
        {
            for (int i = 0; i < args.Length; i++)
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        /// <summary>The engine's vocabulary, so Test-Repo and the CLI can validate against
        /// the real lists instead of restating them.</summary>
        static int ListKnown()
        {
            Console.Out.WriteLine("effects," + string.Join(",", Palette.EffectNames()));
            Console.Out.WriteLine("directions," + string.Join(",", Palette.DirectionNames()));
            Console.Out.WriteLine("easings," + string.Join(",", Palette.EasingNames()));
            Console.Out.Flush();
            return 0;
        }

        /// <summary>Every theme, built-in and user, so the CLI can list what is available
        /// without duplicating Themes' own notion of what "available" means.</summary>
        static int ListThemes()
        {
            var w = Console.Out;
            w.WriteLine("name,builtin,states,description");
            foreach (var info in Themes.List())
            {
                Theme t; string err;
                var count = Themes.TryLoad(info.Name, out t, out err) && t.States != null ? t.States.Count : 0;
                w.WriteLine(string.Join(",", new[]
                {
                    info.Name, info.Builtin ? "yes" : "no",
                    count.ToString(CultureInfo.InvariantCulture),
                    (info.Description ?? "").Replace(",", " ")
                }));
            }
            w.Flush();
            return 0;
        }

        /// <summary>Resolve every state through the full layer stack and print it, so the
        /// merge is testable without hardware. --pending takes the same shape StyleStore
        /// holds: state name to a partial StateStyle, or literal null for a tombstone.
        /// --cleared is a comma-separated list of states to Reset before --pending is
        /// applied, so a reset-then-set sequence (StyleStore keeps the two independent)
        /// is testable too - --pending alone cannot express that ordering. --theme seeds
        /// the store from a whole theme before --pending is applied, so a theme's own
        /// resolved output is testable, and an explicit --pending still wins per field.</summary>
        static int ResolveStates(string[] args)
        {
            var configPath = Arg(args, "--config", null);
            DaemonConfig cfg = null;
            if (!string.IsNullOrEmpty(configPath))
            {
                string e;
                cfg = DaemonConfig.Load(configPath, out e);
                if (cfg == null) { Console.Error.WriteLine("bad --config: " + e); return 2; }
            }

            var store = new StyleStore();
            var clearedArg = Arg(args, "--cleared", null);
            if (!string.IsNullOrEmpty(clearedArg))
                foreach (var name in clearedArg.Split(','))
                {
                    var trimmed = name.Trim();
                    if (trimmed.Length > 0) store.Reset(trimmed);
                }

            // Applied before --pending, not after: StyleStore.Set merges a new patch's
            // non-null fields over whatever is already pending for that state, so the
            // patch applied *second* is the one that wins per field. Seeding from the
            // theme here and letting --pending layer on top afterwards is what makes an
            // explicit --pending able to override a theme rather than the reverse.
            var themeName = Arg(args, "--theme", null);
            if (!string.IsNullOrEmpty(themeName))
            {
                Theme t; string terr;
                if (!Themes.TryLoad(themeName, out t, out terr))
                {
                    Console.Error.WriteLine("bad --theme: " + terr);
                    return 2;
                }
                foreach (var kv in t.States) store.Set(kv.Key, kv.Value);
            }

            var pendingJson = Arg(args, "--pending", null);
            if (!string.IsNullOrEmpty(pendingJson))
            {
                Dictionary<string, StateStyle> parsed;
                try { parsed = new JavaScriptSerializer().Deserialize<Dictionary<string, StateStyle>>(pendingJson); }
                catch (Exception ex) { Console.Error.WriteLine("bad --pending: " + ex.Message); return 2; }
                if (parsed != null)
                    foreach (var kv in parsed)
                    {
                        if (kv.Value == null) store.Reset(kv.Key);
                        else store.Set(kv.Key, kv.Value);
                    }
            }

            DeviceConfig dev = null;
            var deviceName = Arg(args, "--device", null);
            if (!string.IsNullOrEmpty(deviceName))
            {
                // Every other bad argument in this harness reports and returns 2 rather
                // than quietly answering a different question - a --device with no
                // --config to look it up in must not silently resolve as "no device".
                if (cfg == null) { Console.Error.WriteLine("--device requires --config"); return 2; }
                dev = cfg.Devices.FirstOrDefault(x => x != null &&
                          string.Equals(x.Name, deviceName, StringComparison.OrdinalIgnoreCase));
                if (dev == null)
                {
                    Console.Error.WriteLine("unknown --device: " + deviceName);
                    return 2;
                }
            }

            var segments = ArgInt(args, "--segments", 10);
            if (segments < 1) segments = 1;

            var w = Console.Out;
            w.WriteLine("state,effect,color,color2,hz,brightness,direction,easing,tail,depth,fullseconds");
            foreach (var name in Enum.GetNames(typeof(Activity)))
            {
                Activity a;
                Enum.TryParse(name, true, out a);
                var r = Palette.ResolveFor(cfg, store, dev, a, segments);
                w.WriteLine(string.Join(",", new[]
                {
                    name, r.Effect, r.Color.ToHex(), r.HasColor2 ? r.Color2.ToHex() : "none",
                    r.Hz.ToString("0.###", CultureInfo.InvariantCulture),
                    r.Brightness.ToString(CultureInfo.InvariantCulture),
                    r.Direction, r.Easing,
                    r.Tail.ToString("0.###", CultureInfo.InvariantCulture),
                    r.Depth.ToString("0.###", CultureInfo.InvariantCulture),
                    r.FullSeconds.ToString("0.###", CultureInfo.InvariantCulture)
                }));
            }
            w.Flush();
            return 0;
        }

        /// <summary>Print the spliced config to stdout without writing anything, so the
        /// riskiest code in the daemon is testable against hostile fixtures.
        ///
        /// --states is normally the literal States map to write, verbatim. But when
        /// --cleared is also given (same comma-separated shape --resolve-states takes),
        /// --states is instead read as patches: each is applied through a StyleStore
        /// alongside the clears, and what gets spliced in is store.Merged(cfg). That is
        /// the only way to exercise "cleared and also patched" end-to-end - Merged is
        /// what save actually feeds RenderStates, and TrySpliceStates alone cannot express
        /// "drop the config entry, then merge a patch onto nothing" the way Merged does.
        ///
        /// --out <path> routes the same states through ConfigWriter.TrySave against a
        /// scratch copy at that path instead of printing a dry-run splice. Without it,
        /// nothing ever calls TrySave: its round-trip guard, its atomic replace, and its
        /// use of the target file's own indentation all go untested.</summary>
        static int SpliceStates(string[] args)
        {
            var configPath = Arg(args, "--config", null);
            if (string.IsNullOrEmpty(configPath)) { Console.Error.WriteLine("--splice-states needs --config"); return 2; }
            if (!File.Exists(configPath)) { Console.Error.WriteLine("no such config: " + configPath); return 2; }

            var statesJson = Arg(args, "--states", null);
            if (string.IsNullOrEmpty(statesJson)) { Console.Error.WriteLine("--splice-states needs --states"); return 2; }

            Dictionary<string, StateStyle> parsed;
            try { parsed = new JavaScriptSerializer().Deserialize<Dictionary<string, StateStyle>>(statesJson); }
            catch (Exception ex) { Console.Error.WriteLine("bad --states: " + ex.Message); return 2; }
            if (parsed == null) parsed = new Dictionary<string, StateStyle>();

            Dictionary<string, StateStyle> states;
            var clearedArg = Arg(args, "--cleared", null);
            if (!string.IsNullOrEmpty(clearedArg))
            {
                string e;
                var cfg = DaemonConfig.Load(configPath, out e);
                if (cfg == null) { Console.Error.WriteLine("bad --config: " + e); return 2; }

                var store = new StyleStore();
                foreach (var name in clearedArg.Split(','))
                {
                    var trimmed = name.Trim();
                    if (trimmed.Length > 0) store.Reset(trimmed);
                }
                foreach (var kv in parsed)
                {
                    if (kv.Value == null) store.Reset(kv.Key);
                    else store.Set(kv.Key, kv.Value);
                }
                states = store.Merged(cfg);
            }
            else
            {
                states = parsed;
            }

            var outPath = Arg(args, "--out", null);
            if (!string.IsNullOrEmpty(outPath))
            {
                try { File.Copy(configPath, outPath, true); }
                catch (Exception ex) { Console.Error.WriteLine("could not stage --out: " + ex.Message); return 2; }

                string saveError;
                if (!ConfigWriter.TrySave(outPath, states, out saveError))
                {
                    Console.Error.WriteLine("save failed: " + saveError);
                    return 2;
                }
                Console.Out.Write(File.ReadAllText(outPath));
                Console.Out.Flush();
                return 0;
            }

            var original = File.ReadAllText(configPath);
            string result, error;
            if (!ConfigWriter.TrySpliceStates(original, ConfigWriter.RenderStates(states, 2), out result, out error))
            {
                Console.Error.WriteLine("splice failed: " + error);
                return 2;
            }
            Console.Out.Write(result);
            Console.Out.Flush();
            return 0;
        }

        static string Arg(string[] args, string name, string dflt)
        {
            for (int i = 0; i < args.Length - 1; i++)
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            return dflt;
        }

        static int ArgInt(string[] args, string name, int dflt)
        {
            int v;
            return int.TryParse(Arg(args, name, null), NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : dflt;
        }

        static double ArgDouble(string[] args, string name, double dflt)
        {
            double v;
            return double.TryParse(Arg(args, name, null), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : dflt;
        }
    }
}
