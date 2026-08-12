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
        public static Frame Render(ResolvedStyle style, double t, double tInState, int segments)
        {
            var effect = style.Effect;      // already normalised and lowercased by Palette
            var hz = style.Hz;              // already clamped above zero by Palette
            var color = style.Color;

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
                    return new Frame { Solid = color, Segments = cells };
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
                    return new Frame { Solid = color, Segments = cells };
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
}
