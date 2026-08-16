using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;

namespace GoveeLights
{
    /// <summary>
    /// Fixed-rate tick that turns the resolved activity state into Govee calls.
    ///
    /// Measured latency is ~0.5ms per control call (they are fire-and-forget UDP sends,
    /// not round trips), so we are not latency-bound. The limits here exist to be kind
    /// to the devices and the LAN, not because the API cannot keep up.
    /// </summary>
    public sealed class Renderer : IDisposable
    {
        class DeviceRuntime
        {
            public DeviceConfig Cfg;
            public int Segments;
            public Rgb LastRgb = new Rgb(-1, -1, -1);
            public string LastSegCsv;
            public int LastBrightness = -1;
            public DateTime LastSendAt = DateTime.MinValue;
            public DateTime LastKeepaliveAt = DateTime.MinValue;
            public bool RazerPrimed;
            public DateTime RazerPrimedAt = DateTime.MinValue;
            public DateTime LastSegSendAt = DateTime.MinValue;
            public bool SwitchedOn;
            public DateTime LastTraceAt = DateTime.MinValue;
        }

        readonly IGoveeTransport _govee;
        readonly SessionStore _sessions;
        readonly Func<DaemonConfig> _cfg;
        readonly StyleStore _styles;
        readonly Thread _thread;
        volatile bool _running = true;

        readonly List<DeviceRuntime> _devices = new List<DeviceRuntime>();
        readonly object _devGate = new object();

        readonly Stopwatch _clock = Stopwatch.StartNew();

        // Token bucket, refilled per tick.
        double _tokens;
        DateTime _lastRefill = DateTime.UtcNow;

        Activity _current = Activity.Offline;
        Activity _previous = Activity.Offline;
        DateTime _transitionStart = DateTime.MinValue;

        /// <summary>When the state we are fading OUT of started. The outgoing frame has to
        /// be rendered with its own time-in-state, not the incoming state's: progress reads
        /// tInState, so reusing the fresh _transitionStart collapsed a filled bar to empty
        /// for the whole TransitionMs window - the jump cut the cross-fade exists to remove,
        /// just moved onto the outgoing frame.
        ///
        /// DateTime.MinValue on the very first transition is correct, not a hole: the
        /// elapsed value is then enormous, and progress clamps frac to 1 (Effects.Shape),
        /// so it renders a full bar. "A state whose start we never recorded has been
        /// running forever" is the right reading, and progress is the only shape that looks
        /// at tInState at all.</summary>
        DateTime _prevTransitionStart = DateTime.MinValue;

        // Test override, set by POST /test.
        Activity? _forced;
        DateTime _forcedUntil = DateTime.MinValue;

        public Activity Current => _current;
        public int SendCount { get; private set; }
        public DateTime LastActivityAt { get; private set; } = DateTime.UtcNow;

        public Renderer(IGoveeTransport govee, SessionStore sessions, Func<DaemonConfig> cfg, StyleStore styles)
        {
            _govee = govee;
            _sessions = sessions;
            _cfg = cfg;
            _styles = styles;
            _thread = new Thread(Loop) { Name = "renderer", IsBackground = true };
            _thread.Start();
        }

        public void Force(Activity a, int holdMs)
        {
            _forced = a;
            _forcedUntil = DateTime.UtcNow.AddMilliseconds(holdMs);
            LastActivityAt = DateTime.UtcNow;
        }

        /// <summary>Rebuild the device roster from config plus what the API reports.
        /// GetDeviceBaseInfo is authoritative for segment counts - device_info.ini lies.</summary>
        public void SyncDevices()
        {
            var cfg = _cfg();
            var discovered = _govee.Devices;

            lock (_devGate)
            {
                // Rebuilding must not forget what the wire already knows: losing
                // RazerPrimed here made every config save restart the DreamView
                // engagement dwell, and losing SwitchedOn re-switched devices that were
                // already on. Matched by name, the only identity the API has.
                var prior = _devices.ToDictionary(x => x.Cfg.Name, x => x, StringComparer.OrdinalIgnoreCase);
                _devices.Clear();

                // No explicit config: drive everything that reports LAN control on.
                if (cfg.Devices == null || cfg.Devices.Count == 0)
                {
                    foreach (var d in discovered.Where(x => x.LanOn))
                        _devices.Add(Adopt(new DeviceRuntime
                        {
                            Cfg = new DeviceConfig { Name = d.Name, Enabled = true, Animate = true, BrightnessCap = 100 },
                            Segments = d.SegmentNums
                        }, prior));
                }
                else
                {
                    foreach (var c in cfg.Devices)
                    {
                        // A null element survives Normalize now that it no longer throws
                        // there, and SyncDevices runs from the DevicesLoaded callback -
                        // outside the render tick's catch - so an unguarded deref here
                        // would surface as an unhandled exception out of the SDK.
                        if (c == null || !c.Enabled) continue;
                        var found = discovered.FirstOrDefault(x =>
                            string.Equals(x.Name, c.Name, StringComparison.OrdinalIgnoreCase));

                        if (found == null)
                        {
                            Log.Warn("device_missing", "configured device not reported by Govee",
                                new Dictionary<string, object> { { "device", c.Name } });
                            continue;
                        }
                        if (!found.LanOn)
                        {
                            Log.Warn("device_no_lan", "device has LAN control off; skipping",
                                new Dictionary<string, object> { { "device", c.Name } });
                            continue;
                        }
                        _devices.Add(Adopt(new DeviceRuntime
                        {
                            Cfg = c,
                            Segments = c.Segments > 0 ? c.Segments : found.SegmentNums
                        }, prior));
                    }
                }

                Log.Info("devices_synced", "render roster", new Dictionary<string, object>
                {
                    { "count", _devices.Count },
                    { "devices", string.Join(",", _devices.Select(d => d.Cfg.Name + "[" + d.Segments + "]")) }
                });

                // Prime DreamView now rather than lazily at the first segment frame:
                // engagement takes ~3-5s (camera-measured), so priming at sync means the
                // dwell has usually elapsed before any segment state is entered and
                // animations start instantly instead of opening flattened. No
                // RefreshDevices here - SyncDevices runs from the DevicesLoaded callback,
                // and refreshing from inside it would loop.
                foreach (var d in _devices)
                {
                    if (d.Segments > 1 && d.Cfg.Animate && d.Cfg.ManageRazerSwitch && !d.RazerPrimed)
                    {
                        _govee.Razer(d.Cfg.Name, true);
                        d.RazerPrimed = true;
                        d.RazerPrimedAt = DateTime.UtcNow;
                    }
                }
            }
        }

        /// <summary>Carry wire-state from a device's previous runtime across a roster
        /// rebuild. The device did not change because the config was saved; treating it
        /// as new re-primes, re-switches and re-sends things the hardware already has.</summary>
        static DeviceRuntime Adopt(DeviceRuntime fresh, Dictionary<string, DeviceRuntime> prior)
        {
            DeviceRuntime old;
            if (prior.TryGetValue(fresh.Cfg.Name, out old))
            {
                fresh.LastRgb = old.LastRgb;
                fresh.LastSegCsv = old.LastSegCsv;
                fresh.LastBrightness = old.LastBrightness;
                fresh.LastSendAt = old.LastSendAt;
                fresh.LastKeepaliveAt = old.LastKeepaliveAt;
                fresh.RazerPrimed = old.RazerPrimed;
                fresh.RazerPrimedAt = old.RazerPrimedAt;
                fresh.LastSegSendAt = old.LastSegSendAt;
                fresh.SwitchedOn = old.SwitchedOn;
            }
            return fresh;
        }

        void Loop()
        {
            while (_running)
            {
                var cfg = _cfg();
                try { TickOnce(cfg); }
                catch (Exception ex) { Log.Exception("render_tick_failed", ex); }

                // Nothing is being rendered when Offline, so ticking at animation rate
                // burns wakeups for no reason. Idling cheaply is what makes it
                // reasonable to leave the daemon running rather than shutting it down
                // and hoping something restarts it.
                var tick = _current == Activity.Offline
                    ? Math.Max(cfg.Render.TickMs, cfg.Render.IdleTickMs)
                    : Math.Max(10, cfg.Render.TickMs);

                Thread.Sleep(tick);
            }
        }

        void TickOnce(DaemonConfig cfg)
        {
            _sessions.Tick();
            RefillTokens(cfg);

            SessionState winner;
            var resolved = _sessions.Resolve(out winner);

            if (_forced.HasValue)
            {
                if (DateTime.UtcNow < _forcedUntil) resolved = _forced.Value;
                else _forced = null;
            }

            // Global off switches. Hooks are still accepted; we just stop rendering.
            if (!cfg.Enabled || cfg.InQuietHours(DateTime.Now)) resolved = Activity.Offline;
            if (!_govee.Connected) { _govee.EnsureConnected(); return; }

            if (resolved != _current)
            {
                _previous = _current;
                _current = resolved;
                _prevTransitionStart = _transitionStart;    // before it is overwritten
                _transitionStart = DateTime.UtcNow;
                LastActivityAt = DateTime.UtcNow;
                Log.Info("render_state", _current.ToString());

                if (_current == Activity.Offline) ApplySessionEnd(cfg);
            }

            if (_current == Activity.Offline) return;

            // Cross-fade so state changes read as smooth rather than as a jump cut.
            var sinceTransition = (DateTime.UtcNow - _transitionStart).TotalMilliseconds;
            var t = _clock.Elapsed.TotalSeconds;
            var tInState = (DateTime.UtcNow - _transitionStart).TotalSeconds;
            var tInPrevState = (DateTime.UtcNow - _prevTransitionStart).TotalSeconds;

            var fading = cfg.Render.TransitionMs > 0 && sinceTransition < cfg.Render.TransitionMs;
            var mix = fading ? sinceTransition / cfg.Render.TransitionMs : 1.0;

            List<DeviceRuntime> snapshot;
            lock (_devGate) snapshot = _devices.ToList();

            foreach (var d in snapshot)
            {
                var segs = d.Cfg.Animate ? d.Segments : 1;

                // Resolved per device, not once for the tick: a spatial effect (chase,
                // comet, ...) falls back to breathe when a device has no strip to be
                // spatial on, and that fallback depends on this device's own segment
                // count (Palette.ResolveFor).
                var style = Palette.ResolveFor(cfg, _styles, d.Cfg, _current, segs);
                var frame = Effects.Render(style, t, tInState, segs);

                if (fading)
                {
                    // Render the outgoing state too and blend, so motion cross-fades
                    // rather than snapping. Only inside the TransitionMs window.
                    // tInPrevState, not tInState: the outgoing state's clock did not
                    // restart just because we left it.
                    //
                    // Solid-to-solid only. A fade touching a segment frame is a jump cut
                    // instead: blending emits a fresh interpolated CSV every tick, and
                    // that ~25/s burst is exactly the flood that wedges the strip into
                    // ignoring all writes (camera-verified 2026-08-15; Test-Emits.ps1
                    // guards it).
                    var prev = Palette.ResolveFor(cfg, _styles, d.Cfg, _previous, segs);
                    var prevFrame = Effects.Render(prev, t, tInPrevState, segs);
                    if (frame.Segments == null && prevFrame.Segments == null)
                        frame = Effects.Blend(prevFrame, frame, mix);
                }

                Emit(cfg, d, style, frame);
            }
        }

        void Emit(DaemonConfig cfg, DeviceRuntime d, ResolvedStyle style, Frame frame)
        {
            var now = DateTime.UtcNow;

            // Once per second per device at DEBUG, before any early return: what this
            // device actually resolved to and which wire path the frame is taking.
            //
            // DeviceSegmentsColor returns "0" whether or not the strip honours it, so a
            // flattened segment write is invisible from the return code, invisible in the
            // log, and invisible to any headless test. Diagnosing that cost an hour of
            // guessing from the outside; this is the trace that would have answered it in
            // one run.
            if (Log.Level <= LogLevel.Debug && (now - d.LastTraceAt).TotalMilliseconds >= 1000)
            {
                d.LastTraceAt = now;
                Log.Debug("emit_trace", d.Cfg.Name, new Dictionary<string, object>
                {
                    { "state", _current.ToString() },
                    { "effect", style.Effect },
                    { "segs", d.Segments },
                    { "animate", d.Cfg.Animate },
                    { "path", frame.Segments == null ? "solid" : "segments[" + frame.Segments.Length + "]" },
                    { "cells", frame.Segments == null
                        ? frame.Solid.ToHex()
                        : string.Join(" ", frame.Segments.Take(4).Select(c => c.ToHex())) },
                    { "razerPrimed", d.RazerPrimed },
                    { "gradientOff", cfg.IsGradientOff },
                    { "brightness", style.Brightness }
                });
            }

            if ((now - d.LastSendAt).TotalMilliseconds < cfg.Render.MinDeviceIntervalMs) return;

            // Devices must be on before anything else has an effect.
            if (!d.SwitchedOn)
            {
                _govee.Switch(d.Cfg.Name, true);
                d.SwitchedOn = true;
            }

            // Brightness is a separate round trip, so send it only when the state's target
            // changes - animation intensity is baked into RGB instead.
            var wantBrightness = style.Brightness;
            if (wantBrightness > 0)
            {
                var capped = Math.Min(wantBrightness, d.Cfg.BrightnessCap <= 0 ? 100 : d.Cfg.BrightnessCap);
                if (Math.Abs(capped - d.LastBrightness) >= 2)
                {
                    if (!TakeToken()) return;
                    _govee.Brightness(d.Cfg.Name, capped);
                    d.LastBrightness = capped;
                }
            }

            var keepaliveDue = (now - d.LastKeepaliveAt).TotalSeconds >= cfg.Render.KeepaliveSeconds;

            if (frame.Segments != null && d.Segments > 1)
            {
                if (d.Cfg.ManageRazerSwitch)
                {
                    // Segment colours are rendered as a flattened average - not dropped,
                    // not an error - unless Razer/DreamView mode is on AND has finished
                    // engaging. The mode is a session with a TTL of a few minutes, not a
                    // latch, so the prime refreshes on a period; that also covers a
                    // device that power-cycled invisibly (its prime is necessarily old
                    // by the time segments resume). Gated on RazerPrimedAt, so the dwell
                    // below cannot retrigger this every tick and reset its own clock.
                    var period = cfg.Render.SegmentRePrimeSeconds;
                    var expired = d.RazerPrimed && period > 0
                        && (now - d.RazerPrimedAt).TotalSeconds > period;
                    if (!d.RazerPrimed || expired)
                    {
                        _govee.Razer(d.Cfg.Name, true);
                        _govee.RefreshDevices();
                        d.RazerPrimed = true;
                        d.RazerPrimedAt = now;
                    }
                }

                // Writes inside the engagement window come out flattened anyway, so send
                // the same average deliberately - but as a UNIFORM SEGMENT CSV, never
                // via DeviceColorControl: a Color write silently knocks H6066 panels out
                // of DreamView (camera kill-test 2026-08-16), which would murder the
                // very engagement this dwell is waiting for. Pre-engagement, a uniform
                // CSV flattens to exactly itself, so the look is identical either way.
                // The state's colour still appears instantly; motion joins ~5s later.
                if (d.RazerPrimed &&
                    (now - d.RazerPrimedAt).TotalMilliseconds < cfg.Render.SegmentEngageMs)
                {
                    var avg = Average(frame.Segments);
                    SendSegments(cfg, d,
                        string.Join(",", Enumerable.Repeat(avg.ToHex(), frame.Segments.Length)),
                        keepaliveDue, now);
                    return;
                }

                SendSegments(cfg, d,
                    string.Join(",", frame.Segments.Select(c => c.ToHex())),
                    keepaliveDue, now);
            }
            else if (d.Segments > 1 && d.Cfg.ManageRazerSwitch)
            {
                // Solid frames for a segment-capable device ride the segments path as a
                // uniform CSV (the same trick ApplySessionEnd uses): DeviceColorControl
                // silently kills DreamView on H6066 panels, so using it here would make
                // every solid interlude cost a re-engagement dwell on the next effect.
                // With this, the prime lives for the whole session.
                SendSegments(cfg, d,
                    string.Join(",", Enumerable.Repeat(frame.Solid.ToHex(), d.Segments)),
                    keepaliveDue, now);
            }
            else
            {
                SendSolid(cfg, d, frame.Solid, keepaliveDue, now);
            }
        }

        /// <summary>The segment wire path. Paced far below MinDeviceIntervalMs on
        /// purpose: sustained ~20+/s segment floods wedge the strip into ignoring every
        /// write for tens of seconds (camera-verified). Effects still read fine at
        /// 4-6 fps.</summary>
        void SendSegments(DaemonConfig cfg, DeviceRuntime d, string csv, bool keepaliveDue, DateTime now)
        {
            if ((now - d.LastSegSendAt).TotalMilliseconds < cfg.Render.MinSegmentIntervalMs) return;

            if (csv != d.LastSegCsv || keepaliveDue)
            {
                if (!TakeToken()) return;
                _govee.Segments(d.Cfg.Name, csv, cfg.IsGradientOff);
                d.LastSegCsv = csv;
                d.LastRgb = new Rgb(-1, -1, -1);
                d.LastSendAt = now;
                d.LastSegSendAt = now;
                if (keepaliveDue) d.LastKeepaliveAt = now;
                SendCount++;
            }
        }

        /// <summary>The whole-device colour path, shared by solid frames and the
        /// engagement-dwell fallback. Quantized so a smooth curve does not emit
        /// near-identical frames.</summary>
        void SendSolid(DaemonConfig cfg, DeviceRuntime d, Rgb rgb, bool keepaliveDue, DateTime now)
        {
            if (d.LastRgb.R < 0 || rgb.MaxDelta(d.LastRgb) >= cfg.Render.RgbQuantize || keepaliveDue)
            {
                if (!TakeToken()) return;
                _govee.Color(d.Cfg.Name, rgb.R, rgb.G, rgb.B);
                // A Color write silently drops H6066 panels out of DreamView (camera
                // kill-test 2026-08-16; H619A strips tolerate it). Treat the prime as
                // dead so the next segment state re-primes instead of writing into a
                // dead mode - the cost is one engagement dwell per solid-to-segment
                // transition, which is correct on panels and harmless on strips.
                if (d.Segments > 1 && d.Cfg.ManageRazerSwitch) d.RazerPrimed = false;
                d.LastRgb = rgb;
                d.LastSegCsv = null;
                d.LastSendAt = now;
                if (keepaliveDue) d.LastKeepaliveAt = now;
                SendCount++;
            }
        }

        static Rgb Average(Rgb[] cells)
        {
            int r = 0, g = 0, b = 0;
            for (int i = 0; i < cells.Length; i++) { r += cells[i].R; g += cells[i].G; b += cells[i].B; }
            return new Rgb(r / cells.Length, g / cells.Length, b / cells.Length);
        }

        void ApplySessionEnd(DaemonConfig cfg)
        {
            List<DeviceRuntime> snapshot;
            lock (_devGate) snapshot = _devices.ToList();

            var mode = (cfg.OnSessionEnd ?? "rest").ToLowerInvariant();
            Log.Info("session_end_action", mode);

            foreach (var d in snapshot)
            {
                if (mode == "off")
                {
                    _govee.Switch(d.Cfg.Name, false);
                    d.SwitchedOn = false;
                }
                else if (mode == "rest")
                {
                    // The API exposes no way to read a device's colour, so "restore" can only
                    // ever mean "apply the configured resting colour".
                    var rest = Rgb.Parse(cfg.RestColor, new Rgb(255, 217, 160));
                    if (d.Segments > 1 && d.RazerPrimed)
                    {
                        var csv = string.Join(",", Enumerable.Repeat(rest.ToHex(), d.Segments));
                        _govee.Segments(d.Cfg.Name, csv, cfg.IsGradientOff);
                        d.LastSegCsv = csv;
                    }
                    else
                    {
                        _govee.Color(d.Cfg.Name, rest.R, rest.G, rest.B);
                        d.LastRgb = rest;
                    }
                    _govee.Brightness(d.Cfg.Name, cfg.RestBrightness);
                    d.LastBrightness = cfg.RestBrightness;
                }
                // "hold" deliberately does nothing.
            }
        }

        void RefillTokens(DaemonConfig cfg)
        {
            var now = DateTime.UtcNow;
            var dt = (now - _lastRefill).TotalSeconds;
            _lastRefill = now;
            var max = Math.Max(1, cfg.Render.MaxCallsPerSecGlobal);
            _tokens = Math.Min(max, _tokens + dt * max);
        }

        bool TakeToken()
        {
            if (_tokens < 1) return false;
            _tokens -= 1;
            return true;
        }

        public object Status()
        {
            lock (_devGate)
            {
                return new Dictionary<string, object>
                {
                    { "state", _current.ToString() },
                    { "forced", _forced.HasValue ? _forced.Value.ToString() : null },
                    { "sends", SendCount },
                    { "devices", _devices.Select(d => (object)new Dictionary<string, object>
                        {
                            { "name", d.Cfg.Name },
                            { "segments", d.Segments },
                            { "animate", d.Cfg.Animate },
                            { "brightness", d.LastBrightness },
                            { "razerPrimed", d.RazerPrimed }
                        }).ToList() }
                };
            }
        }

        public void Dispose()
        {
            _running = false;
            try { _thread.Join(500); } catch { }
        }
    }
}
