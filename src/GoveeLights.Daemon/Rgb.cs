using System;
using System.Globalization;

namespace GoveeLights
{
    public struct Rgb
    {
        public int R, G, B;
        public Rgb(int r, int g, int b) { R = r; G = g; B = b; }

        public static Rgb Parse(string hex, Rgb fallback)
        {
            Rgb r;
            return TryParse(hex, out r) ? r : fallback;
        }

        /// <summary>Parse without silently swallowing the failure. Callers that know which
        /// field a value came from use this so a malformed colour can be reported the same
        /// way a malformed Effect or Easing already is, rather than turning into grey with
        /// no diagnostic anywhere.</summary>
        public static bool TryParse(string hex, out Rgb rgb)
        {
            rgb = new Rgb(0, 0, 0);
            if (string.IsNullOrEmpty(hex)) return false;
            hex = hex.Trim().TrimStart('#');
            if (hex.Length != 6) return false;
            int v;
            if (!int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v)) return false;
            rgb = new Rgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
            return true;
        }

        public Rgb Scale(double k) => new Rgb(Clamp(R * k), Clamp(G * k), Clamp(B * k));

        public static Rgb Lerp(Rgb a, Rgb b, double t)
        {
            if (t <= 0) return a;
            if (t >= 1) return b;
            return new Rgb(Clamp(a.R + (b.R - a.R) * t), Clamp(a.G + (b.G - a.G) * t), Clamp(a.B + (b.B - a.B) * t));
        }

        public string ToHex() => "#" + R.ToString("X2") + G.ToString("X2") + B.ToString("X2");

        public int MaxDelta(Rgb o) =>
            Math.Max(Math.Abs(R - o.R), Math.Max(Math.Abs(G - o.G), Math.Abs(B - o.B)));

        static int Clamp(double d) => d < 0 ? 0 : (d > 255 ? 255 : (int)Math.Round(d));

        /// <summary>h wraps, s and v are 0..1. Needed by rainbow, which varies hue rather
        /// than intensity and so cannot be expressed as a weight.</summary>
        public static Rgb FromHsv(double h, double s, double v)
        {
            h = h - Math.Floor(h);
            var i = (int)Math.Floor(h * 6) % 6;
            var f = h * 6 - Math.Floor(h * 6);
            var p = v * (1 - s);
            var q = v * (1 - f * s);
            var u = v * (1 - (1 - f) * s);

            double r, g, b;
            switch (i)
            {
                case 0:  r = v; g = u; b = p; break;
                case 1:  r = q; g = v; b = p; break;
                case 2:  r = p; g = v; b = u; break;
                case 3:  r = p; g = q; b = v; break;
                case 4:  r = u; g = p; b = v; break;
                default: r = v; g = p; b = q; break;
            }
            return new Rgb(Clamp(r * 255), Clamp(g * 255), Clamp(b * 255));
        }
    }
}
