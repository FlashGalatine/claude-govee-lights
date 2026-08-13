using System;
using System.Collections.Generic;

namespace GoveeLights
{
    /// <summary>
    /// Everything mutable about styles: unsaved edits and the transient preview slot.
    ///
    /// One owner and one lock, so the control plane never reaches into Program's config
    /// field - which the render thread reads 25 times a second.
    ///
    /// Clearing and patching are two independent facts about a state, tracked
    /// separately: `_cleared` says "suppress the config layer for this state", `_pending`
    /// says "apply this patch on top of whatever survives". A single dictionary keyed by
    /// a nullable patch cannot hold both at once - a patch after a clear would have to
    /// overwrite the tombstone to be stored at all, silently resurrecting the config
    /// layer it was meant to stay clear of. Two collections make "cleared AND patched"
    /// representable instead of losing to whichever call happened last.
    /// </summary>
    public sealed class StyleStore
    {
        readonly object _gate = new object();
        readonly Dictionary<string, StateStyle> _pending =
            new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);
        readonly HashSet<string> _cleared =
            new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        string _previewState;
        StateStyle _previewPatch;
        DateTime _previewUntil = DateTime.MinValue;

        public bool Dirty { get { lock (_gate) return _pending.Count > 0 || _cleared.Count > 0; } }

        public bool TryPending(string state, out StateStyle style)
        {
            lock (_gate) return _pending.TryGetValue(state, out style);
        }

        public bool IsCleared(string state) { lock (_gate) return _cleared.Contains(state); }

        /// <summary>Field-wise patch. A null field in the patch leaves the current value
        /// alone, so `set Thinking --hz 2` does not blank the colour. Does not touch
        /// `_cleared` - patching a state that was reset keeps it cleared; the patch
        /// layers on top of the built-in default instead of the config it suppressed.</summary>
        public void Set(string state, StateStyle patch)
        {
            lock (_gate)
            {
                StateStyle existing;
                _pending.TryGetValue(state, out existing);
                _pending[state] = Merge(existing, patch);
            }
        }

        /// <summary>Suppress the config layer for this state. Leaves any existing patch
        /// alone - `reset` then `set` must resolve to built-in-plus-patch, not
        /// config-plus-patch.</summary>
        public void Reset(string state) { lock (_gate) _cleared.Add(state); }

        /// <summary>Clears every Activity name, plus any key cfg.States actually has -
        /// including one that is not an Activity name (a typo, or a state the engine no
        /// longer defines). Without the union, such a key would survive "reset all" and
        /// `save` would write it straight back to disk.</summary>
        public void ResetAll(DaemonConfig cfg)
        {
            lock (_gate)
            {
                foreach (var name in Enum.GetNames(typeof(Activity))) _cleared.Add(name);
                if (cfg != null && cfg.States != null)
                    foreach (var key in cfg.States.Keys) _cleared.Add(key);
            }
        }

        public void Revert() { lock (_gate) { _pending.Clear(); _cleared.Clear(); } }

        /// <summary>What `save` writes: the config's States with pending applied on top.
        /// A cleared state drops the config layer outright, so a patch on a cleared state
        /// merges onto a null basis rather than the entry it suppressed; a cleared state
        /// with no patch is omitted entirely, which is what makes it fall back to the
        /// built-in defaults on the next load.</summary>
        public Dictionary<string, StateStyle> Merged(DaemonConfig cfg)
        {
            var o = new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);
            if (cfg != null && cfg.States != null)
                foreach (var kv in cfg.States) o[kv.Key] = kv.Value;

            lock (_gate)
            {
                foreach (var state in _cleared) o.Remove(state);

                foreach (var kv in _pending)
                {
                    StateStyle basis;
                    o[kv.Key] = Merge(o.TryGetValue(kv.Key, out basis) ? basis : null, kv.Value);
                }
            }
            return o;
        }

        /// <summary>Stores a fresh Merge result, not the caller's object - the render
        /// thread reads this off-lock, and Set never hands out a reference the caller
        /// still holds either.</summary>
        public void SetPreview(string state, StateStyle patch, int holdMs)
        {
            lock (_gate)
            {
                _previewState = state;
                _previewPatch = Merge(null, patch);
                _previewUntil = DateTime.UtcNow.AddMilliseconds(holdMs);
            }
        }

        /// <summary>The preview patch for a state, or null once it has expired. Expiry is
        /// read at resolve time rather than swept by a timer - the render loop asks 25
        /// times a second, so there is nothing a timer would do sooner.</summary>
        public StateStyle Preview(string state)
        {
            lock (_gate)
            {
                if (_previewPatch == null || DateTime.UtcNow >= _previewUntil) return null;
                return string.Equals(_previewState, state, StringComparison.OrdinalIgnoreCase)
                    ? _previewPatch : null;
            }
        }

        /// <summary>Non-null fields of `patch` win over `basis`. Either may be null.</summary>
        public static StateStyle Merge(StateStyle basis, StateStyle patch)
        {
            if (patch == null) return basis;
            if (basis == null) basis = new StateStyle();
            return new StateStyle
            {
                Color       = patch.Color       ?? basis.Color,
                Color2      = patch.Color2      ?? basis.Color2,
                Effect      = patch.Effect      ?? basis.Effect,
                Hz          = patch.Hz          ?? basis.Hz,
                Brightness  = patch.Brightness  ?? basis.Brightness,
                Direction   = patch.Direction   ?? basis.Direction,
                Easing      = patch.Easing      ?? basis.Easing,
                Tail        = patch.Tail        ?? basis.Tail,
                Depth       = patch.Depth       ?? basis.Depth,
                FullSeconds = patch.FullSeconds ?? basis.FullSeconds
            };
        }
    }
}
