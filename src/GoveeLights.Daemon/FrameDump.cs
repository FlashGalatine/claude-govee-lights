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

            StateStyle style;
            if (!string.IsNullOrEmpty(styleJson))
            {
                try { style = new JavaScriptSerializer().Deserialize<StateStyle>(styleJson); }
                catch (Exception ex) { Console.Error.WriteLine("bad --style: " + ex.Message); return 2; }
                if (style == null) { Console.Error.WriteLine("bad --style: null"); return 2; }
            }
            else
            {
                Activity a;
                if (!Enum.TryParse(stateName ?? "Thinking", true, out a))
                {
                    Console.Error.WriteLine("unknown --state: " + stateName);
                    return 2;
                }
                style = Palette.For(null, a);
            }

            var color = Rgb.Parse(style.Color, new Rgb(120, 120, 120));

            var w = Console.Out;
            w.WriteLine("# effect=" + (style.Effect ?? "solid") +
                        " hz=" + style.Hz.ToString("0.###", CultureInfo.InvariantCulture) +
                        " color=" + color.ToHex() +
                        " segments=" + segments + " fps=" + fps);

            var frames = (int)Math.Round(seconds * fps);
            for (int i = 0; i < frames; i++)
            {
                var t = (double)i / fps;
                var f = Effects.Render(style, t, segments, color);
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
