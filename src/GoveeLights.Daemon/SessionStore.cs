using System;
using System.Collections.Generic;
using System.Linq;

namespace GoveeLights
{
    /// <summary>Activity states, ordered by how much they deserve your attention.</summary>
    public enum Activity
    {
        Offline = 0,
        Idle = 10,
        Done = 25,
        Thinking = 40,
        ToolRead = 45,
        ToolOther = 46,
        ToolWeb = 50,
        ToolMcp = 55,
        Compacting = 60,
        ToolAgent = 65,
        ToolEdit = 74,
        ToolShell = 75,
        Error = 90,
        WaitingUser = 100
    }

    public class SessionState
    {
        public string SessionId;
        public string Cwd;
        public Activity State = Activity.Idle;

        public DateTime EnteredAt = DateTime.UtcNow;
        public DateTime LastEventAt = DateTime.UtcNow;

        /// <summary>Every state is held at least this long so a burst of fast tool calls
        /// reads as activity rather than a strobe.</summary>
        public DateTime MinUntil = DateTime.MinValue;

        /// <summary>Latched states (error, done) refuse to be overwritten until this passes.</summary>
        public DateTime StickyUntil = DateTime.MinValue;

        /// <summary>A queued transition that a new tool call can cancel. This is what
        /// collapses 20 rapid Reads into one continuous colour.</summary>
        public Activity? Pending;
        public DateTime PendingAt = DateTime.MaxValue;

        public int SubagentDepth;
    }

    public class SessionStore
    {
        readonly object _gate = new object();
        readonly Dictionary<string, SessionState> _sessions = new Dictionary<string, SessionState>(StringComparer.Ordinal);

        public TimeSpan Ttl = TimeSpan.FromMinutes(30);
        public TimeSpan MinHold = TimeSpan.FromMilliseconds(400);
        public TimeSpan SettleDelay = TimeSpan.FromMilliseconds(250);

        public int Count { get { lock (_gate) return _sessions.Count; } }

        public SessionState GetOrAdd(string id, string cwd)
        {
            lock (_gate)
            {
                SessionState s;
                if (!_sessions.TryGetValue(id ?? "", out s))
                {
                    s = new SessionState { SessionId = id ?? "", Cwd = cwd };
                    _sessions[s.SessionId] = s;
                    Log.Info("session_start", "tracking session", new Dictionary<string, object>
                    {
                        { "sessionId", s.SessionId }, { "cwd", cwd }, { "live", _sessions.Count }
                    });
                }
                if (!string.IsNullOrEmpty(cwd)) s.Cwd = cwd;
                s.LastEventAt = DateTime.UtcNow;
                return s;
            }
        }

        public void Remove(string id)
        {
            lock (_gate)
            {
                if (_sessions.Remove(id ?? ""))
                    Log.Info("session_end", "session removed", new Dictionary<string, object>
                    {
                        { "sessionId", id }, { "live", _sessions.Count }
                    });
            }
        }

        /// <summary>Drop a latch early. WaitingUser latches for 15 minutes so it survives
        /// a long permission prompt, but the moment the user answers, the very next event
        /// is lower priority and would otherwise be swallowed for the rest of the latch.
        /// Callers clear explicitly rather than relying on priority.</summary>
        public void ClearSticky(SessionState s)
        {
            lock (_gate) s.StickyUntil = DateTime.MinValue;
        }

        /// <summary>Set a session's state, honouring the minimum-hold and sticky rules.</summary>
        public void Set(SessionState s, Activity next, TimeSpan? sticky = null)
        {
            lock (_gate)
            {
                var now = DateTime.UtcNow;
                // Bump liveness even when the transition is refused, or a session pinned in
                // a latched state would look idle and get evicted by the TTL sweep.
                s.LastEventAt = now;

                // A latched state wins unless the newcomer outranks it.
                if (now < s.StickyUntil && (int)next < (int)s.State) return;

                // A brand-new state must not displace one that has not been visible yet,
                // unless it is more important.
                if (now < s.MinUntil && (int)next < (int)s.State) return;

                s.Pending = null;
                s.PendingAt = DateTime.MaxValue;

                if (s.State != next)
                {
                    s.State = next;
                    s.EnteredAt = now;
                    s.MinUntil = now + MinHold;
                    Log.Debug("state", next.ToString(), new Dictionary<string, object> { { "sessionId", s.SessionId } });
                }
                s.StickyUntil = sticky.HasValue ? now + sticky.Value : DateTime.MinValue;
                s.LastEventAt = now;
            }
        }

        /// <summary>Queue a transition that a subsequent event can cancel.</summary>
        public void Schedule(SessionState s, Activity next)
        {
            lock (_gate)
            {
                s.Pending = next;
                s.PendingAt = DateTime.UtcNow + SettleDelay;
                s.LastEventAt = DateTime.UtcNow;
            }
        }

        /// <summary>Apply due transitions and evict dead sessions. Called each render tick.</summary>
        public void Tick()
        {
            lock (_gate)
            {
                var now = DateTime.UtcNow;

                foreach (var s in _sessions.Values.ToList())
                {
                    if (s.Pending.HasValue && now >= s.PendingAt)
                    {
                        var next = s.Pending.Value;
                        s.Pending = null;
                        s.PendingAt = DateTime.MaxValue;
                        if (now >= s.StickyUntil && s.State != next)
                        {
                            s.State = next;
                            s.EnteredAt = now;
                            s.MinUntil = now + MinHold;
                            Log.Debug("state_settled", next.ToString(), new Dictionary<string, object> { { "sessionId", s.SessionId } });
                        }
                    }

                    // "Done" is a flourish, not a resting state.
                    if (s.State == Activity.Done && now >= s.StickyUntil && now - s.EnteredAt > TimeSpan.FromSeconds(4))
                    {
                        s.State = Activity.Idle;
                        s.EnteredAt = now;
                    }

                    if (now - s.LastEventAt > Ttl)
                    {
                        _sessions.Remove(s.SessionId);
                        Log.Info("session_expired", "no events within TTL", new Dictionary<string, object> { { "sessionId", s.SessionId } });
                    }
                }
            }
        }

        /// <summary>The state actually rendered: highest priority across live sessions,
        /// most recently entered breaking ties.</summary>
        public Activity Resolve(out SessionState winner)
        {
            lock (_gate)
            {
                winner = null;
                foreach (var s in _sessions.Values)
                {
                    if (winner == null ||
                        (int)s.State > (int)winner.State ||
                        ((int)s.State == (int)winner.State && s.EnteredAt > winner.EnteredAt))
                        winner = s;
                }
                return winner == null ? Activity.Offline : winner.State;
            }
        }

        public List<object> Snapshot()
        {
            lock (_gate)
            {
                return _sessions.Values.Select(s => (object)new Dictionary<string, object>
                {
                    { "sessionId", s.SessionId },
                    { "cwd", s.Cwd },
                    { "state", s.State.ToString() },
                    { "forSeconds", Math.Round((DateTime.UtcNow - s.EnteredAt).TotalSeconds, 1) },
                    { "subagents", s.SubagentDepth }
                }).ToList();
            }
        }
    }
}
