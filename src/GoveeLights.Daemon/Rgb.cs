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
            if (string.IsNullOrEmpty(hex)) return fallback;
            hex = hex.Trim().TrimStart('#');
            if (hex.Length != 6) return fallback;
            int v;
            if (!int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v)) return fallback;
            return new Rgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
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
    }
}
