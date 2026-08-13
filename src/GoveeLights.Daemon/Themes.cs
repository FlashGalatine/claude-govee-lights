using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    public sealed class Theme
    {
        public string Name { get; set; }
        public string Description { get; set; }
        public Dictionary<string, StateStyle> States { get; set; }
    }

    public sealed class ThemeInfo
    {
        public string Name;
        public string Description;
        public bool Builtin;
        public bool Shadowed;   // a user theme of the same name is in force
    }

    /// <summary>
    /// Built-in themes live in code, not in files: Ensure-Daemon launches the executable
    /// with no arguments and dist/daemon holds only the exe, so there is no reliable way
    /// to find plugin-relative data. Palette.Defaults() already sets this precedent.
    ///
    /// User themes are one file per theme, and shadow a built-in of the same name. Since
    /// built-ins are never written to, shadowing is always undone by deleting the file.
    /// </summary>
    public static class Themes
    {
        public static string UserDir
        {
            get { return Path.Combine(DaemonConfig.DefaultDir, "themes"); }
        }

        static readonly Regex NamePattern = new Regex(@"^[A-Za-z0-9_-]{1,32}$", RegexOptions.Compiled);

        /// <summary>A theme name becomes a filename, so it is validated rather than
        /// sanitised - a name that needs cleaning up is a name the user should retype.</summary>
        public static bool IsValidName(string name)
        {
            return !string.IsNullOrEmpty(name) && NamePattern.IsMatch(name);
        }

        public static Dictionary<string, Theme> BuiltIn()
        {
            var o = new Dictionary<string, Theme>(StringComparer.OrdinalIgnoreCase);

            o["default"] = new Theme
            {
                Name = "default",
                Description = "The built-in palette",
                States = Palette.Defaults()
            };

            o["muted"] = new Theme
            {
                Name = "muted",
                Description = "Dim and slow, for a shared room",
                States = Scale(Palette.Defaults(), 0.45, 0.5)
            };

            o["vivid"] = new Theme
            {
                Name = "vivid",
                Description = "Brighter and faster",
                States = Scale(Palette.Defaults(), 1.0, 1.6)
            };

            o["mono"] = new Theme
            {
                Name = "mono",
                Description = "One hue; effect carries the distinction",
                States = Monochrome(Palette.Defaults(), "#5B8CFF")
            };

            return o;
        }

        /// <summary>Brightness and rate scaling, clamped to the ranges the engine accepts.
        /// Colours are untouched: a muted theme should read as the same palette turned
        /// down, not as a different one.</summary>
        static Dictionary<string, StateStyle> Scale(Dictionary<string, StateStyle> src,
                                                    double brightness, double hz)
        {
            var o = new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);
            foreach (var kv in src)
            {
                var s = kv.Value;
                var b = s.Brightness.HasValue && s.Brightness.Value > 0
                    ? (int?)Math.Max(1, Math.Min(100, (int)Math.Round(s.Brightness.Value * brightness)))
                    : s.Brightness;
                var h = s.Hz.HasValue && s.Hz.Value > 0 ? (double?)(s.Hz.Value * hz) : s.Hz;
                o[kv.Key] = new StateStyle
                {
                    Color = s.Color, Color2 = s.Color2, Effect = s.Effect,
                    Hz = h, Brightness = b,
                    Direction = s.Direction, Easing = s.Easing,
                    Tail = s.Tail, Depth = s.Depth, FullSeconds = s.FullSeconds
                };
            }
            return o;
        }

        static Dictionary<string, StateStyle> Monochrome(Dictionary<string, StateStyle> src, string hex)
        {
            var o = new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);
            foreach (var kv in src)
            {
                var s = kv.Value;
                o[kv.Key] = new StateStyle
                {
                    Color = hex, Color2 = s.Color2, Effect = s.Effect,
                    Hz = s.Hz, Brightness = s.Brightness,
                    Direction = s.Direction, Easing = s.Easing,
                    Tail = s.Tail, Depth = s.Depth, FullSeconds = s.FullSeconds
                };
            }
            return o;
        }

        public static List<ThemeInfo> List()
        {
            var user = UserNames();
            var o = new List<ThemeInfo>();

            foreach (var kv in BuiltIn())
                o.Add(new ThemeInfo
                {
                    Name = kv.Key,
                    Description = kv.Value.Description,
                    Builtin = true,
                    Shadowed = user.Contains(kv.Key)
                });

            foreach (var n in user)
                o.Add(new ThemeInfo { Name = n, Description = DescribeUser(n), Builtin = false, Shadowed = false });

            return o.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase).ToList();
        }

        static HashSet<string> UserNames()
        {
            var o = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (!Directory.Exists(UserDir)) return o;
                foreach (var f in Directory.GetFiles(UserDir, "*.json"))
                {
                    var n = Path.GetFileNameWithoutExtension(f);
                    if (IsValidName(n)) o.Add(n);
                }
            }
            catch (Exception ex) { Log.Debug("theme_scan_failed", ex.Message); }
            return o;
        }

        static string DescribeUser(string name)
        {
            Theme t; string err;
            return TryLoad(name, out t, out err) && !string.IsNullOrEmpty(t.Description)
                ? t.Description : "(saved theme)";
        }

        /// <summary>A user theme of the same name wins, which is what makes shadowing
        /// work - and reversible, since the built-in is never overwritten.</summary>
        public static bool TryLoad(string name, out Theme theme, out string error)
        {
            theme = null; error = null;
            if (!IsValidName(name)) { error = "invalid theme name"; return false; }

            var path = Path.Combine(UserDir, name + ".json");
            if (File.Exists(path))
            {
                try
                {
                    var ser = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 };
                    theme = ser.Deserialize<Theme>(File.ReadAllText(path));
                    if (theme == null) { error = "theme file is empty"; return false; }
                    if (theme.States == null) { error = "theme has no States"; return false; }
                    theme.Name = name;
                    return true;
                }
                catch (Exception ex) { error = ex.Message; return false; }
            }

            Theme builtin;
            if (BuiltIn().TryGetValue(name, out builtin)) { theme = builtin; return true; }

            error = "no such theme";
            return false;
        }

        public static bool TrySave(string name, Dictionary<string, StateStyle> states, out string error)
        {
            error = null;
            if (!IsValidName(name)) { error = "invalid theme name; use letters, digits, dash or underscore"; return false; }
            if (states == null || states.Count == 0) { error = "nothing to save"; return false; }

            try
            {
                Directory.CreateDirectory(UserDir);
                var t = new Theme { Name = name, Description = "Saved theme", States = states };
                var json = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 }.Serialize(t);
                var path = Path.Combine(UserDir, name + ".json");
                var tmp = path + ".tmp";
                File.WriteAllText(tmp, json);
                if (File.Exists(path)) File.Replace(tmp, path, null);
                else File.Move(tmp, path);
                return true;
            }
            catch (Exception ex) { error = ex.Message; return false; }
        }
    }
}
