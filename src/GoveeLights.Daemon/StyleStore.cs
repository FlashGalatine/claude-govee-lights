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
    /// A key present with a NULL value is a tombstone: "suppress the config layer for
    /// this state". An all-null StateStyle cannot express that, because every-field-null
    /// already means "inherit", which is a no-op.
    /// </summary>
    public sealed class StyleStore
    {
        readonly object _gate = new object();
        readonly Dictionary<string, StateStyle> _pending =
            new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);

        string _previewState;
        StateStyle _previewPatch;
        DateTime _previewUntil = DateTime.MinValue;

        public bool Dirty { get { lock (_gate) return _pending.Count > 0; } }

        public bool TryPending(string state, out StateStyle style)
        {
            lock (_gate) return _pending.TryGetValue(state, out style);
        }

        /// <summary>Field-wise patch. A null field in the patch leaves the current value
        /// alone, so `set Thinking --hz 2` does not blank the colour.</summary>
        public void Set(string state, StateStyle patch)
        {
            lock (_gate)
            {
                StateStyle existing;
                // A tombstone stored as null must not be merged into - patching a
                // "cleared" state starts from empty, not from the config it suppressed.
                if (!_pending.TryGetValue(state, out existing)) existing = null;
                _pending[state] = Merge(existing, patch);
            }
        }

        public void Reset(string state) { lock (_gate) _pending[state] = null; }

        public void ResetAll()
        {
            lock (_gate)
            {
                foreach (var name in Enum.GetNames(typeof(Activity))) _pending[name] = null;
            }
        }

        public void Revert() { lock (_gate) _pending.Clear(); }

        /// <summary>What `save` writes: the config's States with pending applied on top.
        /// Tombstoned states are omitted entirely, which is what makes them fall back to
        /// the built-in defaults on the next load.</summary>
        public Dictionary<string, StateStyle> Merged(DaemonConfig cfg)
        {
            var o = new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);
            if (cfg != null && cfg.States != null)
                foreach (var kv in cfg.States) o[kv.Key] = kv.Value;

            lock (_gate)
            {
                foreach (var kv in _pending)
                {
                    if (kv.Value == null) { o.Remove(kv.Key); continue; }
                    StateStyle basis;
                    o[kv.Key] = Merge(o.TryGetValue(kv.Key, out basis) ? basis : null, kv.Value);
                }
            }
            return o;
        }

        public void SetPreview(string state, StateStyle patch, int holdMs)
        {
            lock (_gate)
            {
                _previewState = state;
                _previewPatch = patch;
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
