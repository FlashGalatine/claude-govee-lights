using System;
using System.Collections.Generic;

namespace GoveeLights
{
    /// <summary>Translates Claude Code hook events into activity states.</summary>
    public class HookMapper
    {
        readonly SessionStore _sessions;
        readonly Dictionary<string, string> _toolClasses;

        static readonly TimeSpan ErrorSticky = TimeSpan.FromMilliseconds(2500);
        static readonly TimeSpan StopFailSticky = TimeSpan.FromSeconds(10);
        static readonly TimeSpan DoneSticky = TimeSpan.FromSeconds(2);
        static readonly TimeSpan WaitingSticky = TimeSpan.FromMinutes(15);

        public HookMapper(SessionStore sessions, Dictionary<string, string> toolClassOverrides)
        {
            _sessions = sessions;
            _toolClasses = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "Bash", "shell" }, { "BashOutput", "shell" }, { "KillShell", "shell" }, { "PowerShell", "shell" },
                { "Edit", "edit" }, { "MultiEdit", "edit" }, { "Write", "edit" }, { "NotebookEdit", "edit" },
                { "Read", "read" }, { "Glob", "read" }, { "Grep", "read" }, { "NotebookRead", "read" },
                { "WebFetch", "web" }, { "WebSearch", "web" },
                { "Task", "agent" }, { "Agent", "agent" }, { "SendMessage", "agent" }, { "Workflow", "agent" }
            };
            if (toolClassOverrides != null)
                foreach (var kv in toolClassOverrides) _toolClasses[kv.Key] = kv.Value;
        }

        /// <param name="hint">The ?e= query hint from hooks.json. Notification payloads do
        /// not reliably carry their matcher, so the URL disambiguates them.</param>
        public void Handle(string eventName, string hint, string sessionId, string cwd, string toolName)
        {
            var name = (eventName ?? hint ?? "").Trim();
            var h = (hint ?? "").Trim().ToLowerInvariant();

            // SessionEnd removes the session outright; everything else creates/refreshes it.
            if (Eq(name, "SessionEnd") || h == "session_end")
            {
                _sessions.Remove(sessionId);
                return;
            }

            var s = _sessions.GetOrAdd(sessionId, cwd);

            switch (h)
            {
                case "permission_prompt":
                case "permission_request":
                    _sessions.Set(s, Activity.WaitingUser, WaitingSticky); return;
                case "idle":
                    _sessions.Set(s, Activity.Idle); return;
                case "stop_error":
                    _sessions.Set(s, Activity.Error, StopFailSticky); return;
            }

            // Any of these means the user has answered (or the turn moved on), so the
            // WaitingUser latch must be released before we try to change state - otherwise
            // its 15-minute stickiness swallows every lower-priority event that follows.
            if (s.State == Activity.WaitingUser && IsWaitingResolver(name))
                _sessions.ClearSticky(s);

            if (Eq(name, "SessionStart")) { _sessions.Set(s, Activity.Idle); return; }
            if (Eq(name, "UserPromptSubmit")) { _sessions.Set(s, Activity.Thinking); return; }

            if (Eq(name, "PreToolUse"))
            {
                _sessions.Set(s, ClassifyTool(toolName));
                return;
            }

            if (Eq(name, "PostToolUse") || Eq(name, "PostToolBatch"))
            {
                // Scheduled, not immediate - a following PreToolUse cancels it.
                _sessions.Schedule(s, Activity.Thinking);
                return;
            }

            if (Eq(name, "PostToolUseFailure")) { _sessions.Set(s, Activity.Error, ErrorSticky); return; }
            if (Eq(name, "PermissionRequest")) { _sessions.Set(s, Activity.WaitingUser, WaitingSticky); return; }
            if (Eq(name, "PermissionDenied")) { _sessions.Set(s, Activity.Thinking); return; }
            if (Eq(name, "Notification")) { return; } // resolved by hint above
            if (Eq(name, "StopFailure")) { _sessions.Set(s, Activity.Error, StopFailSticky); return; }

            if (Eq(name, "Stop"))
            {
                s.SubagentDepth = 0;
                _sessions.Set(s, Activity.Done, DoneSticky);
                return;
            }

            if (Eq(name, "SubagentStart"))
            {
                s.SubagentDepth++;
                _sessions.Set(s, Activity.ToolAgent);
                return;
            }

            if (Eq(name, "SubagentStop"))
            {
                if (s.SubagentDepth > 0) s.SubagentDepth--;
                if (s.SubagentDepth == 0) _sessions.Schedule(s, Activity.Thinking);
                return;
            }

            if (Eq(name, "PreCompact")) { _sessions.Set(s, Activity.Compacting); return; }
            if (Eq(name, "PostCompact")) { _sessions.Set(s, Activity.Thinking); return; }
            if (Eq(name, "TeammateIdle")) { _sessions.Set(s, Activity.Idle); return; }

            Log.Debug("hook_ignored", name, new Dictionary<string, object> { { "hint", hint } });
        }

        public Activity ClassifyTool(string toolName)
        {
            if (string.IsNullOrEmpty(toolName)) return Activity.ToolOther;

            if (toolName.StartsWith("mcp__", StringComparison.OrdinalIgnoreCase)) return Activity.ToolMcp;

            string cls;
            if (!_toolClasses.TryGetValue(toolName, out cls)) return Activity.ToolOther;

            switch (cls)
            {
                case "shell": return Activity.ToolShell;
                case "edit": return Activity.ToolEdit;
                case "read": return Activity.ToolRead;
                case "web": return Activity.ToolWeb;
                case "agent": return Activity.ToolAgent;
                case "mcp": return Activity.ToolMcp;
                default: return Activity.ToolOther;
            }
        }

        /// <summary>Events that prove a permission prompt is no longer waiting on the user.</summary>
        static bool IsWaitingResolver(string name) =>
            Eq(name, "PreToolUse") || Eq(name, "PostToolUse") || Eq(name, "PostToolBatch") ||
            Eq(name, "PostToolUseFailure") || Eq(name, "PermissionDenied") ||
            Eq(name, "UserPromptSubmit") || Eq(name, "Stop") || Eq(name, "StopFailure");

        static bool Eq(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
    }
}
