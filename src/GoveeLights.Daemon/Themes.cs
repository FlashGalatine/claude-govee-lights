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
        /// <summary>Test-only escape hatch: null in production, where UserDir is always
        /// the live %LOCALAPPDATA% folder the running daemon also uses. Test-Repo.ps1
        /// sets this (via --themes-dir) so theme tests read and write a scratch
        /// directory instead of colliding with whatever the daemon has on the machine
        /// actually running the suite. Internal - nothing but the harness may set it.</summary>
        internal static string UserDirOverride;

        public static string UserDir
        {
            get { return UserDirOverride ?? Path.Combine(DaemonConfig.DefaultDir, "themes"); }
        }

        // \A...\z, not ^...$: .NET's $ matches before a single trailing "\n" even
        // without RegexOptions.Multiline, so "mono\n" would otherwise validate and
        // then land in a filename with a newline baked into it.
        static readonly Regex NamePattern = new Regex(@"\A[A-Za-z0-9_-]{1,32}\z", RegexOptions.Compiled);

        // Windows reserves these as device names regardless of extension - CON, NUL
        // and friends. Nothing in NamePattern excludes them (they are all plain
        // letters/digits), and a name that needs to be a filename should not be able
        // to name a device instead.
        static readonly HashSet<string> ReservedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        };

        /// <summary>A theme name becomes a filename, so it is validated rather than
        /// sanitised - a name that needs cleaning up is a name the user should retype.</summary>
        public static bool IsValidName(string name)
        {
            return !string.IsNullOrEmpty(name) && NamePattern.IsMatch(name) && !ReservedNames.Contains(name);
        }

        /// <summary>True when a theme names exactly the fourteen Activity states - no
        /// gap, no misspelling. A theme with the right *count* but a state named
        /// "ToolShel" would silently fall back to the built-in default for ToolShell;
        /// counting States.Count cannot see that, only the key set can.</summary>
        public static bool IsComplete(Dictionary<string, StateStyle> states)
        {
            if (states == null) return false;
            var want = new HashSet<string>(Enum.GetNames(typeof(Activity)), StringComparer.OrdinalIgnoreCase);
            return want.SetEquals(states.Keys);
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

        /// <summary>Brightness and rate scaling. Brightness is clamped to 1..100; Hz is
        /// NOT clamped - it is multiplied and left as it lands, which is safe only because
        /// every factor used here is small and Palette.Defaults' rates are well under
        /// StyleRoutes' 50 Hz ceiling. A larger factor added later would need a clamp.
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

            string tmp = null;
            try
            {
                Directory.CreateDirectory(UserDir);
                var t = new Theme { Name = name, Description = "Saved theme", States = states };
                var json = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 }.Serialize(t);
                var path = Path.Combine(UserDir, name + ".json");
                tmp = path + ".tmp";
                File.WriteAllText(tmp, json);
                if (File.Exists(path)) File.Replace(tmp, path, null);
                else File.Move(tmp, path);
                return true;
            }
            catch (Exception ex)
            {
                // Don't leave a stray .tmp beside the user's themes if the final
                // replace/move step itself throws - same defect ConfigWriter.TrySave
                // guards against, for the same reason (a locked file, a scan mid-flight).
                try { if (tmp != null && File.Exists(tmp)) File.Delete(tmp); } catch { /* best effort */ }
                error = ex.Message;
                return false;
            }
        }
    }
}
