using System;

namespace GoveeLights
{
    /// <summary>One rendered frame for one device.</summary>
    public class Frame
    {
        public Rgb Solid;
        public Rgb[] Segments;      // null = use Solid via DeviceColorControl
    }

    /// <summary>
    /// The Govee API has no effects of its own, so every animation is computed here and
    /// pushed as discrete frames.
    ///
    /// An effect is a pure shape: weights in 0..1, one per segment, knowing nothing about
    /// modifiers. Shared stages then apply direction, easing, depth and colour in that
    /// fixed order. Writing modifiers once is what keeps eleven effects from disagreeing
    /// about what "reverse" means.
    /// </summary>
    public static class Effects
    {
        public static Frame Render(ResolvedStyle s, double t, double tInState, int segments)
        {
            var n = segments < 1 ? 1 : segments;

            // Spatial effects have nothing to say on a single-zone device.
            var effect = s.Effect;
            if (n <= 1 && IsSpatial(effect)) effect = "breathe";

            var w = Shape(effect, t, tInState, n, s);
            w = ApplyDirection(w, s, t);
            ApplyEasing(w, s.Easing);
            ApplyDepth(w, s.Depth);
            return ToFrame(w, s, n);
        }

        static bool IsSpatial(string effect)
        {
            switch (effect)
            {
                case "chase": case "comet": case "wipe": case "progress": return true;
                default: return false;
            }
        }

        // ---- shapes -----------------------------------------------------------------

        /// <summary>Returns one weight per segment - or a single weight when the effect is
        /// uniform across the device. That length-1 case is load-bearing: it is what makes
        /// ToFrame emit a whole-device colour instead of a segment array, and what makes
        /// direction a no-op for effects that have no direction.</summary>
        static double[] Shape(string effect, double t, double tInState, int n, ResolvedStyle s)
        {
            switch (effect)
            {
                case "breathe":
                {
                    var k = (Math.Sin(t * 2 * Math.PI * s.Hz) + 1) / 2;
                    return new[] { k };
                }

                case "pulse":
                {
                    // Raw sine; the cubic that makes it snap is the default easing.
                    var k = (Math.Sin(t * 2 * Math.PI * s.Hz) + 1) / 2;
                    return new[] { k };
                }

                case "blink":
                {
                    var on = ((int)Math.Floor(t * s.Hz * 2)) % 2 == 0 ? 1.0 : 0.0;
                    return new[] { on };
                }

                case "chase":
                {
                    var w = new double[n];
                    var head = (t * s.Hz * n) % n;
                    for (int i = 0; i < n; i++)
                    {
                        var d = CircularDistance(i, head, n);
                        w[i] = d <= 0.5 * s.Tail ? 1.0
                             : (d <= 1.5 * s.Tail ? 0.45
                             : (d <= 2.5 * s.Tail ? 0.12 : 0.02));
                    }
                    return w;
                }

                case "comet":
                {
                    var w = new double[n];
                    var head = (t * s.Hz * n) % n;
                    for (int i = 0; i < n; i++)
                    {
                        // Trailing decay only - the tail lags behind the head.
                        var back = head - i;
                        if (back < 0) back += n;
                        w[i] = Math.Max(0.02, Math.Exp(-back / (n * 0.22 * s.Tail)));
                    }
                    return w;
                }

                default: // "solid"
                    return new[] { 1.0 };
            }
        }

        static double CircularDistance(int i, double head, int n)
        {
            var d = Math.Abs(i - head);
            return Math.Min(d, n - d);
        }

        // ---- stages -----------------------------------------------------------------

        /// <summary>Reverse mirrors the array, which turns a travelling wave around and
        /// flips a fill. Pingpong mirrors on odd cycles only, so motion bounces instead
        /// of wrapping. Both are no-ops on a single zone.</summary>
        static double[] ApplyDirection(double[] w, ResolvedStyle s, double t)
        {
            if (w.Length <= 1) return w;

            bool mirror;
            switch (s.Direction)
            {
                case "reverse":  mirror = true; break;
                case "pingpong": mirror = ((int)Math.Floor(t * s.Hz)) % 2 != 0; break;
                default:         mirror = false; break;
            }
            if (!mirror) return w;

            var o = new double[w.Length];
            for (int i = 0; i < w.Length; i++) o[i] = w[w.Length - 1 - i];
            return o;
        }

        static void ApplyEasing(double[] w, string easing)
        {
            if (easing == "linear") return;
            for (int i = 0; i < w.Length; i++)
            {
                var x = w[i] < 0 ? 0 : (w[i] > 1 ? 1 : w[i]);
                switch (easing)
                {
                    case "sine":  x = (1 - Math.Cos(x * Math.PI)) / 2; break;
                    case "cubic": x = x * x * x; break;
                    case "expo":  x = x <= 0 ? 0 : Math.Pow(2, 10 * (x - 1)); break;
                }
                w[i] = x;
            }
        }

        /// <summary>Rescale into [depth, 1] so the colour never fully disappears.</summary>
        static void ApplyDepth(double[] w, double depth)
        {
            if (depth <= 0) return;
            for (int i = 0; i < w.Length; i++) w[i] = depth + (1 - depth) * w[i];
        }

        static Frame ToFrame(double[] w, ResolvedStyle s, int n)
        {
            // Uniform colour is cheaper and more reliable through DeviceColorControl than
            // through a segment array, so do not fill segments unnecessarily. A length-1
            // weight array is exactly the old Whole() path: keep it byte-identical or the
            // goldens - and the wire traffic - both change.
            if (w.Length <= 1) return new Frame { Solid = Mix(s, w[0]), Segments = null };

            var cells = new Rgb[n];
            for (int i = 0; i < n; i++) cells[i] = Mix(s, w[i]);
            return new Frame { Solid = s.Color, Segments = cells };
        }

        static Rgb Mix(ResolvedStyle s, double w)
        {
            return s.HasColor2 ? Rgb.Lerp(s.Color2, s.Color, w) : s.Color.Scale(w);
        }
    }
}
