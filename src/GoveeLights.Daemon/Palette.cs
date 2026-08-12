using System;
using System.Collections.Generic;

namespace GoveeLights
{
    /// <summary>A fully-populated style. No nullables: every field has been resolved,
    /// so effects never have to ask "was this set?".</summary>
    public class ResolvedStyle
    {
        public Rgb    Color;
        public Rgb    Color2;
        public bool   HasColor2;
        public string Effect      = "solid";
        public double Hz          = 0.6;
        public int    Brightness  = -1;
        public string Direction   = "forward";
        public string Easing      = "linear";
        public double Tail        = 1.0;
        public double Depth       = 0.0;
        public double FullSeconds = 30.0;
    }

    public static class Palette
    {
        public static readonly string[] KnownEffects =
            { "solid", "breathe", "pulse", "blink", "chase", "comet", "wipe", "progress", "sparkle", "rainbow" };
        static readonly string[] KnownDirections = { "forward", "reverse", "pingpong" };
        static readonly string[] KnownEasings    = { "linear", "sine", "cubic", "expo" };

        /// <summary>Built-in per-state defaults. Config entries layer over these.</summary>
        public static Dictionary<string, StateStyle> Defaults()
        {
            return new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase)
            {
                { "Idle",        new StateStyle { Color = "#1E2A3A", Effect = "breathe", Hz = 0.12, Brightness = 25 } },
                { "Thinking",    new StateStyle { Color = "#7B4DFF", Effect = "breathe", Hz = 0.6,  Brightness = 55 } },
                { "ToolRead",    new StateStyle { Color = "#06B6D4", Effect = "chase",   Hz = 0.5,  Brightness = 50 } },
                { "ToolEdit",    new StateStyle { Color = "#22C55E", Effect = "chase",   Hz = 0.6,  Brightness = 60 } },
                { "ToolShell",   new StateStyle { Color = "#FF7A18", Effect = "chase",   Hz = 0.8,  Brightness = 60 } },
                { "ToolWeb",     new StateStyle { Color = "#3B82F6", Effect = "chase",   Hz = 0.5,  Brightness = 50 } },
                { "ToolMcp",     new StateStyle { Color = "#8B5CF6", Effect = "chase",   Hz = 0.5,  Brightness = 50 } },
                { "ToolAgent",   new StateStyle { Color = "#D946EF", Effect = "comet",   Hz = 0.7,  Brightness = 60 } },
                { "ToolOther",   new StateStyle { Color = "#94A3B8", Effect = "solid",   Hz = 0.5,  Brightness = 45 } },
                { "Compacting",  new StateStyle { Color = "#00C8A0", Effect = "chase",   Hz = 0.35, Brightness = 45 } },
                { "WaitingUser", new StateStyle { Color = "#FFB000", Effect = "pulse",   Hz = 1.3,  Brightness = 95 } },
                { "Error",       new StateStyle { Color = "#FF2020", Effect = "blink",   Hz = 2.5,  Brightness = 80 } },
                { "Done",        new StateStyle { Color = "#22DD55", Effect = "solid",   Hz = 1.0,  Brightness = 70 } },
                { "Offline",     new StateStyle { Color = "#FFD9A0", Effect = "solid",   Hz = 0.0,  Brightness = 60 } }
            };
        }

        // Resolve runs once per device per tick, so it must not rebuild the default map
        // every time. Nothing mutates these, so a shared instance is safe.
        static readonly Dictionary<string, StateStyle> _stateDefaults = Defaults();

        /// <summary>The weakest layer, keyed by effect. Only breathe, pulse, blink and
        /// sparkle get an entry here - their floors rescale linearly into [Depth, 1], so
        /// expressing them as a Depth modifier changes no output. Chase and comet keep
        /// their own falloff/tail shapes hardcoded in Effects (chase's 0.45/0.12/0.02
        /// steps, comet's Math.Max(0.02, ...) exponential decay) and are given Depth = 0
        /// here deliberately: neither shape is a simple rescale into [Depth, 1], so do
        /// not try to derive them from this table.</summary>
        static StateStyle EffectDefaults(string effect)
        {
            switch (effect)
            {
                case "breathe": return new StateStyle { Depth = 0.35 };
                case "pulse":   return new StateStyle { Depth = 0.08, Easing = "cubic" };
                case "blink":   return new StateStyle { Depth = 0.06 };
                case "sparkle": return new StateStyle { Depth = 0.06 };
                default:        return new StateStyle();
            }
        }

        /// <summary>Layers, weakest first: effect defaults, state defaults, config, device.
        /// A non-null field in a later layer wins; null means inherit.</summary>
        public static ResolvedStyle Resolve(DaemonConfig cfg, DeviceConfig device, Activity state)
        {
            var key = state.ToString();
            var layers = new List<StateStyle>(3);

            StateStyle s;
            if (_stateDefaults.TryGetValue(key, out s)) layers.Add(s);
            else layers.Add(_stateDefaults["Idle"]);

            if (cfg != null && cfg.States != null && cfg.States.TryGetValue(key, out s) && s != null)
                layers.Add(s);
            if (device != null && device.States != null && device.States.TryGetValue(key, out s) && s != null)
                layers.Add(s);

            return ResolveStyle(layers.ToArray());
        }

        public static ResolvedStyle ResolveStyle(params StateStyle[] layers)
        {
            if (layers == null) layers = new StateStyle[0];

            // Effect first: the weakest layer is keyed by it.
            var effect = Norm(Pick(layers, x => x.Effect), KnownEffects, "solid", "Effect");

            var all = new StateStyle[layers.Length + 1];
            all[0] = EffectDefaults(effect);
            Array.Copy(layers, 0, all, 1, layers.Length);

            var r = new ResolvedStyle();
            r.Effect = effect;
            r.Color  = Rgb.Parse(Pick(all, x => x.Color), new Rgb(120, 120, 120));

            // "none" is an explicit clear: without it, a stronger layer could never
            // revert an inherited Color2 back to single-colour once a weaker layer sets it.
            var c2 = Pick(all, x => x.Color2);
            r.HasColor2 = !string.IsNullOrEmpty(c2) && !string.Equals(c2, "none", StringComparison.OrdinalIgnoreCase);
            r.Color2 = r.HasColor2 ? Rgb.Parse(c2, new Rgb(0, 0, 0)) : new Rgb(0, 0, 0);

            r.Hz = PickN(all, x => x.Hz, 0.6);
            if (r.Hz <= 0) r.Hz = 0.6;               // Offline stores Hz 0; solid ignores it anyway

            r.Brightness = PickN(all, x => x.Brightness, -1);
            r.Direction  = Norm(Pick(all, x => x.Direction), KnownDirections, "forward", "Direction");
            r.Easing     = Norm(Pick(all, x => x.Easing), KnownEasings, "linear", "Easing");

            r.Tail = PickN(all, x => x.Tail, 1.0);
            if (r.Tail <= 0) r.Tail = 1.0;

            r.Depth = PickN(all, x => x.Depth, 0.0);
            if (r.Depth < 0) r.Depth = 0;
            if (r.Depth > 1) r.Depth = 1;

            r.FullSeconds = PickN(all, x => x.FullSeconds, 30.0);
            if (r.FullSeconds <= 0) r.FullSeconds = 30.0;

            return r;
        }

        static string Pick(StateStyle[] layers, Func<StateStyle, string> f)
        {
            for (int i = layers.Length - 1; i >= 0; i--)
            {
                if (layers[i] == null) continue;
                var v = f(layers[i]);
                if (!string.IsNullOrEmpty(v)) return v;
            }
            return null;
        }

        static T PickN<T>(StateStyle[] layers, Func<StateStyle, T?> f, T dflt) where T : struct
        {
            for (int i = layers.Length - 1; i >= 0; i--)
            {
                if (layers[i] == null) continue;
                var v = f(layers[i]);
                if (v.HasValue) return v.Value;
            }
            return dflt;
        }

        // A typo must not silently change how the lights behave, but Resolve runs 25x a
        // second - warning every tick would drown the log. Warn once per distinct value.
        static readonly HashSet<string> _warned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        static string Norm(string value, string[] known, string dflt, string field)
        {
            if (string.IsNullOrEmpty(value)) return dflt;
            var v = value.Trim().ToLowerInvariant();
            for (int i = 0; i < known.Length; i++) if (known[i] == v) return v;

            var tag = field + ":" + v;
            lock (_warned)
            {
                if (_warned.Add(tag))
                    Log.Warn("style_unknown_value", "falling back to default",
                        new Dictionary<string, object> { { "field", field }, { "value", value }, { "using", dflt } });
            }
            return dflt;
        }
    }
}
