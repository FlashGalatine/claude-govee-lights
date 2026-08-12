using System;
using System.Collections.Generic;

namespace GoveeLights
{
    /// <summary>One rendered frame for one device.</summary>
    public class Frame
    {
        public Rgb Solid;
        public Rgb[] Segments;      // null = use Solid via DeviceColorControl
        public int Brightness = -1; // -1 = do not send
    }

    public static class Effects
    {
        /// <summary>
        /// Renders a style at a point in time. The Govee API has no effects of its own,
        /// so every animation is computed here and pushed as discrete frames.
        /// </summary>
        /// <param name="segments">Segment count; &lt;= 1 renders whole-device only.</param>
        public static Frame Render(StateStyle style, double t, int segments, Rgb color)
        {
            var effect = (style.Effect ?? "solid").ToLowerInvariant();
            var hz = style.Hz <= 0 ? 0.6 : style.Hz;

            switch (effect)
            {
                case "breathe":
                {
                    // Sine between a floor and full, so the colour never fully disappears.
                    var k = 0.35 + 0.65 * (Math.Sin(t * 2 * Math.PI * hz) + 1) / 2;
                    return Whole(color.Scale(k), segments);
                }

                case "pulse":
                {
                    // Sharper than breathe - shaped to sit dark longer and snap bright.
                    var raw = (Math.Sin(t * 2 * Math.PI * hz) + 1) / 2;
                    var k = 0.08 + 0.92 * Math.Pow(raw, 3);
                    return Whole(color.Scale(k), segments);
                }

                case "blink":
                {
                    var on = ((int)Math.Floor(t * hz * 2)) % 2 == 0;
                    return Whole(on ? color : color.Scale(0.06), segments);
                }

                case "chase":
                {
                    if (segments <= 1) goto case "breathe";
                    var head = (t * hz * segments) % segments;
                    var cells = new Rgb[segments];
                    for (int i = 0; i < segments; i++)
                    {
                        var d = CircularDistance(i, head, segments);
                        var k = d <= 0.5 ? 1.0 : (d <= 1.5 ? 0.45 : (d <= 2.5 ? 0.12 : 0.02));
                        cells[i] = color.Scale(k);
                    }
                    return new Frame { Solid = color, Segments = cells, Brightness = style.Brightness };
                }

                case "comet":
                {
                    if (segments <= 1) goto case "breathe";
                    var head = (t * hz * segments) % segments;
                    var cells = new Rgb[segments];
                    for (int i = 0; i < segments; i++)
                    {
                        // Trailing decay only - the tail lags behind the head.
                        var back = head - i;
                        if (back < 0) back += segments;
                        var k = Math.Max(0.02, Math.Exp(-back / (segments * 0.22)));
                        cells[i] = color.Scale(k);
                    }
                    return new Frame { Solid = color, Segments = cells, Brightness = style.Brightness };
                }

                default: // "solid"
                    return Whole(color, segments);
            }
        }

        static Frame Whole(Rgb c, int segments)
        {
            // Uniform colour is cheaper and more reliable through DeviceColorControl than
            // through a segment array, so do not fill segments unnecessarily.
            return new Frame { Solid = c, Segments = null, Brightness = -1 };
        }

        static double CircularDistance(int i, double head, int n)
        {
            var d = Math.Abs(i - head);
            return Math.Min(d, n - d);
        }
    }

    public static class Palette
    {
        /// <summary>Built-in defaults. Config entries override per state.</summary>
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

        public static StateStyle For(Dictionary<string, StateStyle> config, Activity state)
        {
            var key = state.ToString();
            StateStyle s;
            if (config != null && config.TryGetValue(key, out s) && s != null && !string.IsNullOrEmpty(s.Color)) return s;
            var d = Defaults();
            return d.TryGetValue(key, out s) ? s : d["Idle"];
        }
    }
}
