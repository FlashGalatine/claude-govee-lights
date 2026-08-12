using System;
using System.Globalization;
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
                    dev = cfg.Devices.FirstOrDefault(x => string.Equals(x.Name, deviceName, StringComparison.OrdinalIgnoreCase));
                style = Palette.ResolveFor(cfg, dev, a, segments);
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
                var cells = f.Segments ?? new[] { f.Solid };
                w.WriteLine(t.ToString("0.000", CultureInfo.InvariantCulture) + "," +
                            string.Join(",", cells.Select(c => c.ToHex()).ToArray()));
            }
            w.Flush();
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
