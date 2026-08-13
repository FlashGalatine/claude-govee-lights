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
        static Action<Activity, int> _force;
        static readonly JavaScriptSerializer _json = new JavaScriptSerializer();

        // Sane ceilings so a typo like --hz 1000000 cannot reach the strip: only a floor
        // was enforced originally, and the renderer does not clamp the top either.
        const double MaxHz = 50.0;
        const double MaxTail = 25.0;
        const double MaxFullSeconds = 3600.0;

        /// <summary>Serialises the whole save sequence (snapshot -> write -> clear)
        /// against every other mutating route. Without this, a /styles/set landing
        /// between Save's snapshot and its Revert is silently wiped: Revert clears
        /// everything, not just what Save actually wrote. The individual StyleStore
        /// methods are locked internally, but that only protects each call - not the
        /// multi-call sequence Save is made of.</summary>
        static readonly object _saveGate = new object();

        public static void Init(Func<DaemonConfig> cfg, StyleStore styles, string configPath,
                                Action onSaved, Action<Activity, int> forceState)
        {
            _cfg = cfg; _styles = styles; _configPath = configPath;
            _onSaved = onSaved; _force = forceState;
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

            if (only != null && rows.Count == 0) return HttpResponse.Text(400, UnknownStateError(only));

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
        /// they are asked about independently here rather than inferred from one another.
        ///
        /// A live preview is the strongest of Palette.BuildLayers' layers - stronger than
        /// a device override, stronger than pending itself - so its own note is appended
        /// last, after whatever the state would otherwise resolve to. Without this, /styles
        /// would show a previewed value and call it "config" or "built-in", which is the
        /// opposite of what a preview is for: seeing a look before committing to it.</summary>
        static string SourceOf(DaemonConfig cfg, string state)
        {
            var overridden = cfg != null && cfg.Devices != null && cfg.Devices.Any(d =>
                d != null && d.States != null && d.States.ContainsKey(state));
            var note = overridden ? " + device" : "";
            note += _styles.Preview(state) != null ? " + preview (unsaved)" : "";

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
            var denied = MethodGuard(req);
            if (denied != null) return denied;

            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            string state, stateErr;
            if (!TryState(body, out state, out stateErr)) return HttpResponse.Text(400, stateErr);

            object rawPatch;
            if (!body.TryGetValue("patch", out rawPatch) || rawPatch == null)
                return HttpResponse.Text(400, "no patch");

            StateStyle patch;
            try { patch = _json.ConvertToType<StateStyle>(rawPatch); }
            catch (Exception ex) { return HttpResponse.Text(400, "bad patch: " + ex.Message); }

            string err;
            if (!Validate(patch, out err)) return HttpResponse.Text(400, err);

            // See _saveGate: a set must not land inside Save's snapshot-write-clear
            // window, or Revert would erase it without it ever reaching disk.
            lock (_saveGate) _styles.Set(state, patch);
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

            // Hz 0 is allowed: Palette.Defaults() itself ships Offline with Hz = 0, and
            // the resolver already treats a non-positive Hz as "use the 0.6 default" -
            // rejecting 0 here would stop a user restating a value the daemon seeded.
            if (p.Hz.HasValue && (p.Hz.Value < 0 || p.Hz.Value > MaxHz))
            {
                error = "hz must be between 0 and " + MaxHz.ToString(CultureInfo.InvariantCulture);
                return false;
            }
            if (p.Tail.HasValue && (p.Tail.Value <= 0 || p.Tail.Value > MaxTail))
            {
                error = "tail must be greater than 0 and at most " + MaxTail.ToString(CultureInfo.InvariantCulture);
                return false;
            }
            if (p.FullSeconds.HasValue && (p.FullSeconds.Value <= 0 || p.FullSeconds.Value > MaxFullSeconds))
            {
                error = "fullSeconds must be greater than 0 and at most " + MaxFullSeconds.ToString(CultureInfo.InvariantCulture);
                return false;
            }
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
            var denied = MethodGuard(req);
            if (denied != null) return denied;

            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            bool wantAll;
            string allErr;
            if (!TryAll(body, out wantAll, out allErr)) return HttpResponse.Text(400, allErr);

            if (wantAll)
            {
                lock (_saveGate) _styles.ResetAll(_cfg());
                Log.Info("style_reset", "all");
                return HttpResponse.Json("{\"ok\":true,\"dirty\":true}");
            }

            string state, stateErr;
            if (!TryState(body, out state, out stateErr)) return HttpResponse.Text(400, stateErr);
            lock (_saveGate) _styles.Reset(state);
            Log.Info("style_reset", state);
            return HttpResponse.Json("{\"ok\":true,\"dirty\":true}");
        }

        public static HttpResponse Revert(HttpRequest req)
        {
            var denied = MethodGuard(req);
            if (denied != null) return denied;

            lock (_saveGate) _styles.Revert();
            Log.Info("style_revert", "pending cleared");
            return HttpResponse.Json("{\"ok\":true,\"dirty\":false}");
        }

        public static HttpResponse Save(HttpRequest req)
        {
            var denied = MethodGuard(req);
            if (denied != null) return denied;

            // The whole sequence - snapshot, write, clear - must run as one unit: see
            // _saveGate. Every other mutating route takes the same lock so none of them
            // can land in the middle of it.
            lock (_saveGate)
            {
                if (!_styles.Dirty) return HttpResponse.Json("{\"ok\":true,\"saved\":false,\"reason\":\"nothing to save\"}");

                var merged = _styles.Merged(_cfg());

                // Mute the watcher first: the write we are about to do would otherwise be
                // read back as a foreign edit, rebuilding the config while pending is
                // still live.
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
        }

        public static HttpResponse ThemeList(HttpRequest req)
        {
            var rows = Themes.List().Select(t => (object)new Dictionary<string, object>
            {
                { "name", t.Name }, { "description", t.Description },
                { "builtin", t.Builtin }, { "shadowed", t.Shadowed }
            }).ToList();
            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object> { { "themes", rows } }));
        }

        public static HttpResponse ThemeApply(HttpRequest req)
        {
            var denied = MethodGuard(req);
            if (denied != null) return denied;

            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            object raw;
            if (!body.TryGetValue("name", out raw) || raw == null) return HttpResponse.Text(400, "no theme name");

            Theme t; string err;
            if (!Themes.TryLoad(raw.ToString(), out t, out err)) return HttpResponse.Text(400, err);

            // A theme with no states themes nothing - under total-apply semantics below
            // that would silently reduce to "clear everything", which is not what
            // "apply theme X" means even if X is degenerate.
            if (t.States.Count == 0) return HttpResponse.Text(400, "theme '" + t.Name + "' has no states to apply");

            // See _saveGate: this whole block is exactly the kind of multi-call sequence
            // that must not straddle a concurrent /styles/set or /styles/save.
            lock (_saveGate)
            {
                // A theme is a complete palette, so applying one is total: it replaces
                // whatever was pending, not just the keys this theme happens to mention.
                // ResetAll alone is NOT enough - it only adds to _cleared and never
                // touches _pending, so a patch left over from a *previous* theme (or a
                // plain /styles/set) would otherwise survive underneath: merged field-wise
                // into a state this theme does patch (Set merges onto the existing pending
                // entry), or applied on its own, over the built-in default, for a state
                // this theme does not mention at all. Revert() clears both _pending and
                // _cleared outright; ResetAll(_cfg()) then re-suppresses the config layer
                // for the fresh start a themed state is supposed to get.
                _styles.Revert();
                _styles.ResetAll(_cfg());
                foreach (var kv in t.States)
                {
                    // IsDefined, not just TryParse: a hand-edited theme file's State key is
                    // untrusted the same way a request body's is (see TryState) - TryParse
                    // alone would accept a raw numeric string or a comma list.
                    Activity a;
                    if (!Enum.TryParse(kv.Key, true, out a) || !Enum.IsDefined(typeof(Activity), a)) continue;

                    // Same reasoning as /styles/set's Validate call: a theme file on disk
                    // is exactly as capable of carrying a typo'd Hz or an out-of-range
                    // Brightness as a request body is, and unlike a typed command nobody
                    // notices a bad value sitting in a saved theme file. A skipped state
                    // just falls back to its built-in default instead of silently letting
                    // an unchecked value past the same ceilings /styles/set enforces.
                    string valErr = null;
                    if (kv.Value == null || !Validate(kv.Value, out valErr))
                    {
                        Log.Warn("theme_invalid_state", "skipping unvalidated state in theme",
                            new Dictionary<string, object> { { "theme", t.Name }, { "state", a.ToString() },
                                { "reason", kv.Value == null ? "null style" : valErr } });
                        continue;
                    }
                    _styles.Set(a.ToString(), kv.Value);
                }
            }

            Log.Info("theme_applied", t.Name);
            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object>
            {
                { "ok", true }, { "theme", t.Name }, { "dirty", true }
            }));
        }

        public static HttpResponse ThemeSave(HttpRequest req)
        {
            var denied = MethodGuard(req);
            if (denied != null) return denied;

            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            object raw;
            if (!body.TryGetValue("name", out raw) || raw == null) return HttpResponse.Text(400, "no theme name");

            var name = raw.ToString();
            if (!Themes.IsValidName(name))
                return HttpResponse.Text(400, "invalid theme name; use letters, digits, dash or underscore (max 32)");

            // Read under _saveGate too: a concurrent /styles/save's snapshot-write-clear
            // window must not straddle this read, or a theme could be written from a
            // pending map that a Save() in flight is about to revert.
            Dictionary<string, StateStyle> states;
            lock (_saveGate)
            {
                // Save what is on the lights now: config plus anything unsaved, so a theme
                // is self-contained rather than a diff against whatever config it was cut
                // from.
                states = _styles.Merged(_cfg());
            }

            // A fresh install (or one where nothing has ever been set) merges to an empty
            // map - that is the same "nothing to save" condition /styles/save reports as a
            // no-op 200 rather than an error, so this answers the same way instead of
            // falling through to TrySave's generic 500. The Task 6 CLI has to handle both
            // endpoints' "nothing to do" case identically either way, so match the sibling.
            if (states.Count == 0)
                return HttpResponse.Json("{\"ok\":true,\"saved\":false,\"reason\":\"nothing to save\"}");

            string err;
            if (!Themes.TrySave(name, states, out err)) return HttpResponse.Text(500, "theme save failed: " + err);

            Log.Info("theme_saved", name);
            return HttpResponse.Json("{\"ok\":true}");
        }

        public static HttpResponse Preview(HttpRequest req)
        {
            var denied = MethodGuard(req);
            if (denied != null) return denied;

            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            var holdMs = 8000;
            object rawHold;
            if (body.TryGetValue("holdMs", out rawHold) && rawHold != null)
            {
                // JavaScriptSerializer hands back an Int64 for a JSON integer bigger than
                // Int32.MaxValue, and a plain double for "500.5" - int.TryParse silently
                // fails on both, and used to fall through to the 8000ms default instead of
                // being clamped, so a client sending an oversized or fractional holdMs got
                // a *shorter* preview than one that merely asked for something too big.
                // Parse as double, which covers every shape a JSON number can take here.
                double parsed;
                if (double.TryParse(rawHold.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed)
                    && !double.IsNaN(parsed) && !double.IsInfinity(parsed))
                    holdMs = (int)Math.Max(500.0, Math.Min(60000.0, parsed));
            }

            string state, stateErr;
            if (!TryState(body, out state, out stateErr)) return HttpResponse.Text(400, stateErr);

            StateStyle patch = null;
            object rawPatch;
            if (body.TryGetValue("patch", out rawPatch) && rawPatch != null)
            {
                try { patch = _json.ConvertToType<StateStyle>(rawPatch); }
                catch (Exception ex) { return HttpResponse.Text(400, "bad patch: " + ex.Message); }

                string err;
                if (!Validate(patch, out err)) return HttpResponse.Text(400, err);
            }

            // TryState only ever hands back a canonical, Enum.IsDefined name (see its own
            // comment), so this TryParse cannot fail today - but that is a dependency on
            // TryState's contract, not a redundant check, so it is called out rather than
            // silently discarded. If TryState ever loosened, Activity 0 (Offline) is
            // exactly the kind of wrong-but-plausible fallback that would pass review.
            Activity a;
            Enum.TryParse(state, true, out a);

            // Preview never touches pending: it is a look, not an edit. SetPreview writes
            // to StyleStore's separate preview slot, which Merged()/Save() never read, so
            // this has nothing to do with _saveGate at all - unlike ThemeApply and
            // ThemeSave above, there is no compound sequence here and no risk of racing a
            // save's snapshot-write-clear window.
            if (patch != null) _styles.SetPreview(state, patch, holdMs);
            if (_force != null) _force(a, holdMs);

            Log.Info("style_preview", state);
            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object>
            {
                { "ok", true }, { "state", state }, { "holdMs", holdMs }
            }));
        }

        /// <summary>The /styles*, /themes/apply, /themes/save and /preview routes are the
        /// only ones in this daemon that can destroy user data or reach outside the
        /// process - discard unsaved edits, overwrite the config file, write a theme file,
        /// or force the strip to a state. A GET from a page in the user's browser (an
        /// &lt;img&gt; tag, a stray form) can reach 127.0.0.1 with no way to read the
        /// response, but the side effect still lands. Requiring POST does not stop a
        /// malicious page from sending one, but it does stop the trivial no-JS vectors,
        /// and it is free. GET /themes lists data the same way GET /styles does, so it is
        /// deliberately exempt, same as GET /styles.</summary>
        static HttpResponse MethodGuard(HttpRequest req)
        {
            if (string.Equals(req.Method, "POST", StringComparison.OrdinalIgnoreCase)) return null;
            return HttpResponse.Text(405, "POST required");
        }

        static bool TryBody(HttpRequest req, out Dictionary<string, object> body)
        {
            body = null;
            if (string.IsNullOrEmpty(req.Body)) { body = new Dictionary<string, object>(); return true; }
            try { body = _json.Deserialize<Dictionary<string, object>>(req.Body); }
            catch { return false; }
            return body != null;
        }

        /// <summary>"all" as a real JSON boolean is the documented shape, but a string
        /// "true"/"false" is accepted too - shells and simple HTTP clients stringify
        /// easily. Anything else is rejected with a reason instead of silently falling
        /// through to "unknown or missing state", which is what happened before and told
        /// the caller nothing about what was actually wrong.</summary>
        static bool TryAll(Dictionary<string, object> body, out bool wantAll, out string error)
        {
            wantAll = false; error = null;
            object all;
            if (!body.TryGetValue("all", out all) || all == null) return true;

            if (all is bool) { wantAll = (bool)all; return true; }

            var s = all as string;
            if (s != null)
            {
                bool parsed;
                if (bool.TryParse(s, out parsed)) { wantAll = parsed; return true; }
                error = "\"all\" must be a boolean, got '" + s + "'";
                return false;
            }

            error = "\"all\" must be a boolean";
            return false;
        }

        static string UnknownStateError(string given)
        {
            return "unknown state '" + given + "'; valid: " + string.Join(", ", Enum.GetNames(typeof(Activity)));
        }

        /// <summary>Enum.TryParse on a non-[Flags] enum accepts the decimal underlying
        /// value and comma-separated lists without checking they are defined - so
        /// {"state": 999} or {"state": "Idle,Done"} would otherwise parse into a key that
        /// /styles can never show or reset (it enumerates Enum.GetNames), yet save would
        /// still write it into the config. Enum.IsDefined closes that gap.</summary>
        static bool TryState(Dictionary<string, object> body, out string state, out string error)
        {
            state = null; error = null;
            object raw;
            if (!body.TryGetValue("state", out raw) || raw == null)
            {
                error = "missing state; valid: " + string.Join(", ", Enum.GetNames(typeof(Activity)));
                return false;
            }

            var text = raw.ToString();
            Activity a;
            if (!Enum.TryParse(text, true, out a) || !Enum.IsDefined(typeof(Activity), a))
            {
                error = UnknownStateError(text);
                return false;
            }
            state = a.ToString();     // canonical casing, so the pending map keys match
            return true;
        }
    }
}
