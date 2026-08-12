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
    ///
    /// Spatial effects on a single-zone device are handled upstream, at resolve time
    /// (Palette.ResolveFor/ResolveStyleFor): the resolved style itself is switched to
    /// breathe there, so breathe's own EffectDefaults layer (Depth 0.35) applies. Render
    /// therefore just renders whatever effect the style says - it never rewrites it.
    /// </summary>
    public static class Effects
    {
        public static Frame Render(ResolvedStyle s, double t, double tInState, int segments)
        {
            var n = segments < 1 ? 1 : segments;

            // Pingpong cannot be an array mirror for spatial effects: mirroring flips
            // which end the head appears at, but the circular head position keeps
            // advancing underneath, so at each lap boundary the head would teleport
            // across the strip instead of turning around. Folding time into a triangle
            // wave makes the head genuinely sweep up and back before Shape ever sees it.
            // Non-spatial effects and single zones have no direction to bounce, so the
            // gate leaves them running on unfolded time.
            var tShape = (s.Direction == "pingpong" && n > 1 && Palette.IsSpatial(s.Effect))
                ? FoldTime(t, s.Hz) : t;

            var w = Shape(s.Effect, tShape, tInState, n, s);
            w = ApplyDirection(w, s);
            ApplyEasing(w, s.Easing);
            ApplyDepth(w, s.Depth);
            return ToFrame(w, s);
        }

        /// <summary>Maps time onto a 0..1 triangle wave with the same period as one lap,
        /// so a shape driven by the folded time sweeps forward then genuinely reverses
        /// instead of wrapping circularly and being mirrored on top of that.</summary>
        static double FoldTime(double t, double hz)
        {
            if (hz <= 0) return t;
            var u = (t * hz) % 2.0;              // two laps per fold cycle
            var tri = u <= 1.0 ? u : 2.0 - u;    // 0 -> 1 -> 0
            if (tri >= 1.0) tri = 1.0 - 1e-9;    // head == n would wrap back to 0 for one frame
            return tri / hz;
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
        /// flips a fill. Pingpong is handled earlier, as a time fold before the shape is
        /// computed (see FoldTime) - mirroring the array cannot make a circularly
        /// wrapping head bounce. A no-op on a single zone.</summary>
        static double[] ApplyDirection(double[] w, ResolvedStyle s)
        {
            if (w.Length <= 1) return w;
            if (s.Direction != "reverse") return w;

            var o = new double[w.Length];
            for (int i = 0; i < w.Length; i++) o[i] = w[w.Length - 1 - i];
            return o;
        }

        /// <summary>Clamps to 0..1 unconditionally, even under "linear", so "weights are
        /// in 0..1" stays true for every effect - including future shapes that Shape does
        /// not itself clamp.</summary>
        static void ApplyEasing(double[] w, string easing)
        {
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

        static Frame ToFrame(double[] w, ResolvedStyle s)
        {
            // Uniform colour is cheaper and more reliable through DeviceColorControl than
            // through a segment array, so do not fill segments unnecessarily. A length-1
            // weight array is exactly the old Whole() path: keep it byte-identical or the
            // goldens - and the wire traffic - both change.
            if (w.Length <= 1) return new Frame { Solid = Mix(s, w[0]), Segments = null };

            // Size and iterate on w.Length, not the segment count passed into Render: a
            // shape returning a different-length array (a bug, but a latent one before
            // Task 4 adds four more shapes to this dispatch) must not throw here.
            var cells = new Rgb[w.Length];
            for (int i = 0; i < w.Length; i++) cells[i] = Mix(s, w[i]);
            return new Frame { Solid = s.Color, Segments = cells };
        }

        static Rgb Mix(ResolvedStyle s, double w)
        {
            return s.HasColor2 ? Rgb.Lerp(s.Color2, s.Color, w) : s.Color.Scale(w);
        }
    }
}
