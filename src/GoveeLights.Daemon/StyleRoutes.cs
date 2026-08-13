using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    /// <summary>The control plane's HTTP surface. Kept out of Program.cs, which is already
    /// the largest file in the daemon.</summary>
    public static class StyleRoutes
    {
        static Func<DaemonConfig> _cfg;
        static StyleStore _styles;
        static string _configPath;
        static Action _onSaved;
        static readonly JavaScriptSerializer _json = new JavaScriptSerializer();

        public static void Init(Func<DaemonConfig> cfg, StyleStore styles, string configPath, Action onSaved)
        {
            _cfg = cfg; _styles = styles; _configPath = configPath; _onSaved = onSaved;
        }

        public static HttpResponse Get(HttpRequest req)
        {
            var cfg = _cfg();
            var only = req.Query.ContainsKey("state") ? req.Query["state"] : null;

            var rows = new List<object>();
            foreach (var name in Enum.GetNames(typeof(Activity)))
            {
                if (only != null && !string.Equals(only, name, StringComparison.OrdinalIgnoreCase)) continue;

                Activity a;
                if (!Enum.TryParse(name, true, out a)) continue;
                var r = Palette.ResolveFor(cfg, _styles, null, a, 10);

                rows.Add(new Dictionary<string, object>
                {
                    { "state", name },
                    { "effect", r.Effect },
                    { "color", r.Color.ToHex() },
                    { "color2", r.HasColor2 ? r.Color2.ToHex() : null },
                    { "hz", r.Hz }, { "brightness", r.Brightness },
                    { "direction", r.Direction }, { "easing", r.Easing },
                    { "tail", r.Tail }, { "depth", r.Depth }, { "fullSeconds", r.FullSeconds },
                    { "source", SourceOf(cfg, name) }
                });
            }

            if (only != null && rows.Count == 0) return HttpResponse.Text(400, "unknown state: " + only);

            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object>
            {
                { "dirty", _styles.Dirty }, { "states", rows }
            }));
        }

        /// <summary>The strongest layer that contributed anything, which is what a user
        /// means by "where did this come from".
        ///
        /// A per-device override is called out separately rather than folded in: this row
        /// resolves with device null, so the values shown are the global ones, and a
        /// device overriding this state means what you see is not what that strip shows.
        /// Saying so is the whole point of the column.
        ///
        /// Cleared and patched are independent facts in StyleStore (a state can be both -
        /// "reset Thinking" then "set Thinking --hz 2" lands on built-in-plus-patch), so
        /// they are asked about independently here rather than inferred from one another.</summary>
        static string SourceOf(DaemonConfig cfg, string state)
        {
            var overridden = cfg != null && cfg.Devices != null && cfg.Devices.Any(d =>
                d != null && d.States != null && d.States.ContainsKey(state));
            var note = overridden ? " + device" : "";

            var cleared = _styles.IsCleared(state);
            StateStyle pend;
            var patched = _styles.TryPending(state, out pend);

            if (cleared && patched) return "reset + override (unsaved)" + note;
            if (cleared) return "reset (unsaved)" + note;
            if (patched) return "override (unsaved)" + note;
            if (cfg != null && cfg.States != null && cfg.States.ContainsKey(state)) return "config" + note;
            return "built-in" + note;
        }

        public static HttpResponse Set(HttpRequest req)
        {
            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            string state;
            if (!TryState(body, out state)) return HttpResponse.Text(400, "unknown or missing state");

            object rawPatch;
            if (!body.TryGetValue("patch", out rawPatch) || rawPatch == null)
                return HttpResponse.Text(400, "no patch");

            StateStyle patch;
            try { patch = _json.ConvertToType<StateStyle>(rawPatch); }
            catch (Exception ex) { return HttpResponse.Text(400, "bad patch: " + ex.Message); }

            string err;
            if (!Validate(patch, out err)) return HttpResponse.Text(400, err);

            _styles.Set(state, patch);
            Log.Info("style_set", state);
            return HttpResponse.Json("{\"ok\":true,\"dirty\":true}");
        }

        /// <summary>Interactive input fails loudly. The resolver deliberately falls back on
        /// an unknown value and logs - correct for a file read 25 times a second, wrong for
        /// a command someone just typed.</summary>
        static bool Validate(StateStyle p, out string error)
        {
            error = null;
            if (!OneOf(p.Effect, Palette.EffectNames(), "effect", out error)) return false;
            if (!OneOf(p.Direction, Palette.DirectionNames(), "direction", out error)) return false;
            if (!OneOf(p.Easing, Palette.EasingNames(), "easing", out error)) return false;

            if (!HexOk(p.Color, out error)) return false;
            if (p.Color2 != null && !string.Equals(p.Color2, "none", StringComparison.OrdinalIgnoreCase)
                && !HexOk(p.Color2, out error)) return false;

            if (p.Hz.HasValue && p.Hz.Value <= 0) { error = "hz must be greater than 0"; return false; }
            if (p.Tail.HasValue && p.Tail.Value <= 0) { error = "tail must be greater than 0"; return false; }
            if (p.FullSeconds.HasValue && p.FullSeconds.Value <= 0) { error = "fullSeconds must be greater than 0"; return false; }
            if (p.Depth.HasValue && (p.Depth.Value < 0 || p.Depth.Value > 1)) { error = "depth must be between 0 and 1"; return false; }
            if (p.Brightness.HasValue && (p.Brightness.Value < -1 || p.Brightness.Value > 100))
            { error = "brightness must be -1, or between 0 and 100"; return false; }

            return true;
        }

        static bool OneOf(string value, string[] known, string label, out string error)
        {
            error = null;
            if (value == null) return true;
            if (known.Any(k => string.Equals(k, value, StringComparison.OrdinalIgnoreCase))) return true;
            error = "unknown " + label + " '" + value + "'; valid: " + string.Join(", ", known);
            return false;
        }

        static bool HexOk(string value, out string error)
        {
            error = null;
            if (value == null) return true;
            var t = value.Trim().TrimStart('#');
            int _;
            if (t.Length == 6 && int.TryParse(t, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out _)) return true;
            error = "colour must be six hex digits, e.g. #FF7A18 (got '" + value + "')";
            return false;
        }

        public static HttpResponse Reset(HttpRequest req)
        {
            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            object all;
            if (body.TryGetValue("all", out all) && all is bool && (bool)all)
            {
                _styles.ResetAll(_cfg());
                Log.Info("style_reset", "all");
                return HttpResponse.Json("{\"ok\":true,\"dirty\":true}");
            }

            string state;
            if (!TryState(body, out state)) return HttpResponse.Text(400, "unknown or missing state");
            _styles.Reset(state);
            Log.Info("style_reset", state);
            return HttpResponse.Json("{\"ok\":true,\"dirty\":true}");
        }

        public static HttpResponse Revert(HttpRequest req)
        {
            _styles.Revert();
            Log.Info("style_revert", "pending cleared");
            return HttpResponse.Json("{\"ok\":true,\"dirty\":false}");
        }

        public static HttpResponse Save(HttpRequest req)
        {
            if (!_styles.Dirty) return HttpResponse.Json("{\"ok\":true,\"saved\":false,\"reason\":\"nothing to save\"}");

            var merged = _styles.Merged(_cfg());

            // Mute the watcher first: the write we are about to do would otherwise be read
            // back as a foreign edit, rebuilding the config while pending is still live.
            if (_onSaved != null) _onSaved();

            string err;
            if (!ConfigWriter.TrySave(_configPath, merged, out err))
            {
                Log.Warn("style_save_failed", err);
                return HttpResponse.Text(500, "save failed: " + err);
            }

            _styles.Revert();
            Log.Info("style_saved", _configPath);
            return HttpResponse.Json("{\"ok\":true,\"saved\":true}");
        }

        static bool TryBody(HttpRequest req, out Dictionary<string, object> body)
        {
            body = null;
            if (string.IsNullOrEmpty(req.Body)) { body = new Dictionary<string, object>(); return true; }
            try { body = _json.Deserialize<Dictionary<string, object>>(req.Body); }
            catch { return false; }
            return body != null;
        }

        static bool TryState(Dictionary<string, object> body, out string state)
        {
            state = null;
            object raw;
            if (!body.TryGetValue("state", out raw) || raw == null) return false;
            Activity a;
            if (!Enum.TryParse(raw.ToString(), true, out a)) return false;
            state = a.ToString();     // canonical casing, so the pending map keys match
            return true;
        }
    }
}
