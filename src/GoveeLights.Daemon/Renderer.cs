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
            public bool SwitchedOn;
        }

        readonly GoveeClient _govee;
        readonly SessionStore _sessions;
        readonly Func<DaemonConfig> _cfg;
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

        // Test override, set by POST /test.
        Activity? _forced;
        DateTime _forcedUntil = DateTime.MinValue;

        public Activity Current => _current;
        public int SendCount { get; private set; }
        public DateTime LastActivityAt { get; private set; } = DateTime.UtcNow;

        public Renderer(GoveeClient govee, SessionStore sessions, Func<DaemonConfig> cfg)
        {
            _govee = govee;
            _sessions = sessions;
            _cfg = cfg;
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
                _devices.Clear();

                // No explicit config: drive everything that reports LAN control on.
                if (cfg.Devices == null || cfg.Devices.Count == 0)
                {
                    foreach (var d in discovered.Where(x => x.LanOn))
                        _devices.Add(new DeviceRuntime
                        {
                            Cfg = new DeviceConfig { Name = d.Name, Enabled = true, Animate = true, BrightnessCap = 100 },
                            Segments = d.SegmentNums
                        });
                }
                else
                {
                    foreach (var c in cfg.Devices)
                    {
                        if (!c.Enabled) continue;
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
                        _devices.Add(new DeviceRuntime
                        {
                            Cfg = c,
                            Segments = c.Segments > 0 ? c.Segments : found.SegmentNums
                        });
                    }
                }

                Log.Info("devices_synced", "render roster", new Dictionary<string, object>
                {
                    { "count", _devices.Count },
                    { "devices", string.Join(",", _devices.Select(d => d.Cfg.Name + "[" + d.Segments + "]")) }
                });
            }
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
                _transitionStart = DateTime.UtcNow;
                LastActivityAt = DateTime.UtcNow;
                Log.Info("render_state", _current.ToString());

                if (_current == Activity.Offline) ApplySessionEnd(cfg);
            }

            if (_current == Activity.Offline) return;

            var style = Palette.Resolve(cfg, null, _current);

            // Cross-fade so state changes read as smooth rather than as a jump cut.
            var sinceTransition = (DateTime.UtcNow - _transitionStart).TotalMilliseconds;
            if (cfg.Render.TransitionMs > 0 && sinceTransition < cfg.Render.TransitionMs)
            {
                var prev = Palette.Resolve(cfg, null, _previous);
                var mix = sinceTransition / cfg.Render.TransitionMs;
                style.Color = Rgb.Lerp(prev.Color, style.Color, mix);
                if (style.HasColor2 && prev.HasColor2)
                    style.Color2 = Rgb.Lerp(prev.Color2, style.Color2, mix);
            }

            var t = _clock.Elapsed.TotalSeconds;
            var tInState = (DateTime.UtcNow - _transitionStart).TotalSeconds;

            List<DeviceRuntime> snapshot;
            lock (_devGate) snapshot = _devices.ToList();

            foreach (var d in snapshot)
            {
                var segs = d.Cfg.Animate ? d.Segments : 1;
                var frame = Effects.Render(style, t, tInState, segs);
                Emit(cfg, d, style, frame);
            }
        }

        void Emit(DaemonConfig cfg, DeviceRuntime d, ResolvedStyle style, Frame frame)
        {
            var now = DateTime.UtcNow;
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
                if (!d.RazerPrimed && d.Cfg.ManageRazerSwitch)
                {
                    // Segment colours are silently dropped unless Razer/DreamView mode is on.
                    _govee.Razer(d.Cfg.Name, true);
                    _govee.RefreshDevices();
                    d.RazerPrimed = true;
                }

                var csv = string.Join(",", frame.Segments.Select(c => c.ToHex()));
                if (csv != d.LastSegCsv || keepaliveDue)
                {
                    if (!TakeToken()) return;
                    _govee.Segments(d.Cfg.Name, csv, cfg.IsGradientOff);
                    d.LastSegCsv = csv;
                    d.LastRgb = new Rgb(-1, -1, -1);
                    d.LastSendAt = now;
                    if (keepaliveDue) d.LastKeepaliveAt = now;
                    SendCount++;
                }
            }
            else
            {
                // Quantize so a smooth curve does not emit near-identical frames.
                if (d.LastRgb.R < 0 || frame.Solid.MaxDelta(d.LastRgb) >= cfg.Render.RgbQuantize || keepaliveDue)
                {
                    if (!TakeToken()) return;
                    _govee.Color(d.Cfg.Name, frame.Solid.R, frame.Solid.G, frame.Solid.B);
                    d.LastRgb = frame.Solid;
                    d.LastSegCsv = null;
                    d.LastSendAt = now;
                    if (keepaliveDue) d.LastKeepaliveAt = now;
                    SendCount++;
                }
            }
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
