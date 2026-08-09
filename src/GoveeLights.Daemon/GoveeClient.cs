using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    public class GoveeDevice
    {
        public string Name { get; set; }
        public string SkuType { get; set; }
        public int SegmentNums { get; set; }
        public int IsLANOn { get; set; }
        public bool LanOn => IsLANOn != 0;
    }

    public enum GoveeCode
    {
        Success = 0,
        DesktopNotRunning = 1,
        ProgramError = 100,
        InitFailure = 101,
        DeviceOffline = 102,
        ApiGuidError = 1001,
        EmptyParameter = 1002,
        DeviceNotFound = 1003,
        ColorValueError = 1010,
        InvalidBrightness = 1011,
        NoResponseTimeout = 4000,
        SendFailed = 4001,
        Unparsable = -1
    }

    /// <summary>
    /// The only class that touches GoveeAPI.dll.
    ///
    /// Two constraints from docs/API-NOTES.md are load-bearing here:
    ///
    ///  1. GoveeAPI.PipeClient keeps its pipe and its response-correlation dictionary in
    ///     STATIC fields, keyed by an ExecutionName string. Concurrent calls collide in
    ///     that dictionary and hand responses to the wrong caller - silently wrong
    ///     behaviour, not an exception. So every call is serialized onto one worker
    ///     thread and nothing else is allowed to invoke the API.
    ///
    ///  2. Sibling assemblies are loaded eagerly, never via AssemblyResolve. A resolve
    ///     handler that calls LoadFrom re-enters and kills the process with an
    ///     uncatchable StackOverflowException.
    ///
    /// The bindingRedirect that makes any of this work at all lives in App.config.
    /// </summary>
    public sealed class GoveeClient : IDisposable
    {
        readonly string _dllPath;
        readonly string _guid;
        readonly BlockingCollection<Action> _queue = new BlockingCollection<Action>(new ConcurrentQueue<Action>(), 512);
        readonly Thread _worker;
        readonly JavaScriptSerializer _json = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };

        object _api;
        Type _type;
        MethodInfo _mInit, _mSwitch, _mRazer, _mBrightness, _mColor, _mSegments, _mAllInfo, _mInfoByName;

        volatile bool _connected;
        volatile bool _disposed;
        DateTime _nextRetry = DateTime.MinValue;
        int _retryStep;

        public bool Connected => _connected;
        public string LastError { get; private set; }
        public IReadOnlyList<GoveeDevice> Devices { get; private set; } = new List<GoveeDevice>();

        public GoveeClient(string dllPath, string guid)
        {
            _dllPath = dllPath;
            _guid = guid ?? "";
            _worker = new Thread(WorkerLoop)
            {
                Name = "govee-worker",
                IsBackground = true
            };
            _worker.Start();
        }

        // ---- public API: everything is queued onto the worker ----------------------

        public void Post(Action a)
        {
            if (_disposed) return;
            try { if (!_queue.TryAdd(a)) Log.Warn("queue_full", "dropped a Govee command"); }
            catch (InvalidOperationException) { /* completed */ }
        }

        /// <summary>Runs an action on the worker and waits. Only for startup/shutdown paths -
        /// never call this from the HTTP thread during normal operation.</summary>
        public bool PostAndWait(Action a, int timeoutMs)
        {
            using (var done = new ManualResetEventSlim(false))
            {
                Post(() => { try { a(); } finally { done.Set(); } });
                return done.Wait(timeoutMs);
            }
        }

        public void EnsureConnected() => Post(ConnectIfNeeded);

        public void Switch(string name, bool on) => Post(() => Call(_mSwitch, "DeviceSwitchControl", name, new object[] { name, on ? 1 : 0 }));
        public void Razer(string name, bool on) => Post(() => Call(_mRazer, "DeviceRZSwitchControl", name, new object[] { name, on ? 1 : 0 }));
        public void Brightness(string name, int pct) => Post(() => Call(_mBrightness, "DeviceBrightnessControl", name, new object[] { name, Clamp(pct, 1, 100) }));
        public void Color(string name, int r, int g, int b) => Post(() => Call(_mColor, "DeviceColorControl", name, new object[] { name, Clamp(r, 0, 255), Clamp(g, 0, 255), Clamp(b, 0, 255) }));
        public void Segments(string name, string csv, int gradientOff) => Post(() => Call(_mSegments, "DeviceSegmentsColor", name, new object[] { name, csv, gradientOff }));

        public void RefreshDevices() => Post(LoadDevices);

        // ---- worker ----------------------------------------------------------------

        void WorkerLoop()
        {
            try { Bind(); }
            catch (Exception ex) { Log.Exception("govee_bind_failed", ex); LastError = ex.Message; }

            foreach (var job in _queue.GetConsumingEnumerable())
            {
                if (_disposed) break;
                try { job(); }
                catch (Exception ex) { Log.Exception("govee_job_failed", ex); }
            }
        }

        void Bind()
        {
            if (!File.Exists(_dllPath))
                throw new FileNotFoundException("GoveeAPI.dll not found", _dllPath);

            var dir = Path.GetDirectoryName(_dllPath);

            // Eager preload. See class comment - do NOT replace this with AssemblyResolve.
            int loaded = 0;
            foreach (var f in Directory.GetFiles(dir, "*.dll"))
            {
                if (string.Equals(f, _dllPath, StringComparison.OrdinalIgnoreCase)) continue;
                try { Assembly.LoadFrom(f); loaded++; } catch { /* native / already loaded */ }
            }

            var asm = Assembly.LoadFrom(_dllPath);
            _type = asm.GetType("GoveeAPI.ConnectGovee");
            if (_type == null) throw new InvalidOperationException("GoveeAPI.ConnectGovee not found");

            // Log the real signatures. This is how the DOCX's errors were found in the
            // first place, and it is how a future Govee update will announce itself.
            foreach (var m in _type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly))
            {
                Log.Debug("govee_method", string.Format("{0} {1}({2})", m.ReturnType.Name, m.Name,
                    string.Join(", ", m.GetParameters().Select(p => p.ParameterType.Name + " " + p.Name))));
            }

            _mInit = _type.GetMethod("InitConnect");
            _mSwitch = _type.GetMethod("DeviceSwitchControl");
            _mRazer = _type.GetMethod("DeviceRZSwitchControl");
            _mBrightness = _type.GetMethod("DeviceBrightnessControl");
            _mColor = _type.GetMethod("DeviceColorControl");
            _mSegments = _type.GetMethod("DeviceSegmentsColor");
            _mAllInfo = _type.GetMethod("GetDeviceBaseInfo");
            _mInfoByName = _type.GetMethod("GetDeviceBaseInfoByName");

            if (_mInit == null || _mColor == null)
                throw new InvalidOperationException("GoveeAPI is missing InitConnect or DeviceColorControl");

            if (_mRazer == null) Log.Warn("govee_no_razer", "DeviceRZSwitchControl absent; segment effects may not work");

            _api = Activator.CreateInstance(_type);
            Log.Info("govee_bound", "GoveeAPI loaded", new Dictionary<string, object> { { "siblings", loaded } });

            ConnectIfNeeded();
        }

        void ConnectIfNeeded()
        {
            if (_connected || _api == null) return;
            if (DateTime.UtcNow < _nextRetry) return;

            var sw = Stopwatch.StartNew();
            object raw;
            try { raw = _mInit.Invoke(_api, new object[] { _guid }); }
            catch (Exception ex)
            {
                sw.Stop();
                Log.Exception("govee_init_threw", ex);
                LastError = ex.Message;
                Backoff();
                return;
            }
            sw.Stop();

            var code = ParseCode(raw);
            if (code == GoveeCode.Success)
            {
                _connected = true;
                _retryStep = 0;
                LastError = null;
                Log.Info("govee_connected", "InitConnect succeeded", new Dictionary<string, object> { { "ms", sw.ElapsedMilliseconds } });
                LoadDevices();
            }
            else
            {
                _connected = false;
                LastError = Explain(code, sw.ElapsedMilliseconds);
                Log.Warn("govee_init_failed", LastError, new Dictionary<string, object>
                {
                    { "code", (int)code }, { "ms", sw.ElapsedMilliseconds }
                });
                Backoff();
            }
        }

        void Backoff()
        {
            int[] steps = { 5, 10, 30, 60 };
            var secs = steps[Math.Min(_retryStep, steps.Length - 1)];
            if (_retryStep < steps.Length - 1) _retryStep++;
            _nextRetry = DateTime.UtcNow.AddSeconds(secs);
        }

        /// <summary>Turns a result code into something a human can act on. The two
        /// failure modes that matter are indistinguishable without the timing.</summary>
        static string Explain(GoveeCode code, long ms)
        {
            switch (code)
            {
                case GoveeCode.DesktopNotRunning:
                    return "Govee Desktop is not running.";
                case GoveeCode.ProgramError:
                    return ms < 500
                        ? "Pipe write denied - Govee Desktop is running as administrator. Restart it normally."
                        : "Govee Desktop reported a program error.";
                case GoveeCode.ApiGuidError:
                    return ms > 3000
                        ? "Timed out. Usually a missing System.Runtime.CompilerServices.Unsafe bindingRedirect in App.config, not a bad GUID."
                        : "API GUID rejected.";
                case GoveeCode.NoResponseTimeout:
                    return "No response from Govee Desktop (the light may still have changed).";
                default:
                    return code.ToString();
            }
        }

        void LoadDevices()
        {
            if (!_connected || _mAllInfo == null) return;
            try
            {
                var raw = _mAllInfo.Invoke(_api, new object[0]) as string;
                if (string.IsNullOrEmpty(raw)) return;

                // A bare integer here means an error code rather than a payload.
                int codeOnly;
                if (int.TryParse(raw.Trim(), out codeOnly))
                {
                    Log.Warn("govee_devices_code", "GetDeviceBaseInfo returned a code", new Dictionary<string, object> { { "code", codeOnly } });
                    if (codeOnly == (int)GoveeCode.InitFailure) _connected = false;
                    return;
                }

                var list = _json.Deserialize<List<GoveeDevice>>(raw);
                if (list != null)
                {
                    Devices = list;
                    Log.Info("govee_devices", "device list refreshed", new Dictionary<string, object>
                    {
                        { "count", list.Count },
                        { "lan", string.Join(",", list.Where(d => d.LanOn).Select(d => d.Name + "[" + d.SegmentNums + "]")) }
                    });
                }
            }
            catch (Exception ex) { Log.Exception("govee_devices_failed", ex); }
        }

        GoveeCode Call(MethodInfo m, string label, string device, object[] args)
        {
            if (m == null) return GoveeCode.Unparsable;
            if (!_connected) { ConnectIfNeeded(); if (!_connected) return GoveeCode.InitFailure; }

            var sw = Stopwatch.StartNew();
            object raw;
            try { raw = m.Invoke(_api, args); }
            catch (Exception ex)
            {
                sw.Stop();
                Log.Exception("govee_call_threw:" + label, ex);
                _connected = false;
                Backoff();
                return GoveeCode.ProgramError;
            }
            sw.Stop();

            var code = ParseCode(raw);

            // 4000 means "no response, observe the light". Because control commands go out
            // as UDP from this process, a dropped inbound reply is the normal case on a
            // working setup - treating it as failure would trip breakers on healthy rigs.
            if (code != GoveeCode.Success && code != GoveeCode.NoResponseTimeout)
            {
                Log.Warn("govee_call", label, new Dictionary<string, object>
                {
                    { "device", device }, { "code", (int)code }, { "ms", sw.ElapsedMilliseconds }
                });

                if (code == GoveeCode.InitFailure || code == GoveeCode.DesktopNotRunning)
                {
                    _connected = false;
                    Backoff();
                }
                else if (code == GoveeCode.DeviceNotFound || code == GoveeCode.DeviceOffline)
                {
                    LoadDevices();
                }
            }
            else
            {
                Log.Debug("govee_call", label, new Dictionary<string, object>
                {
                    { "device", device }, { "code", (int)code }, { "ms", sw.ElapsedMilliseconds }
                });
            }

            return code;
        }

        GoveeCode ParseCode(object raw)
        {
            if (raw == null) return GoveeCode.Unparsable;

            if (raw is int) return ToCode((int)raw);

            var s = raw as string;
            if (s == null) return GoveeCode.Unparsable;
            s = s.Trim();

            // Observed format is a bare integer as text ("0"). The PipeSendResult JSON
            // fallback below is a guard, not something seen in practice.
            int n;
            if (int.TryParse(s, out n)) return ToCode(n);

            try
            {
                var obj = _json.Deserialize<Dictionary<string, object>>(s);
                object v;
                if (obj != null && obj.TryGetValue("ExecutionResult", out v) && v != null && int.TryParse(v.ToString(), out n))
                    return ToCode(n);
            }
            catch { }

            Log.Warn("govee_unparsable", "unexpected return payload", new Dictionary<string, object> { { "raw", s } });
            return GoveeCode.Unparsable;
        }

        static GoveeCode ToCode(int n) => Enum.IsDefined(typeof(GoveeCode), n) ? (GoveeCode)n : GoveeCode.Unparsable;

        static int Clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

        public void Dispose()
        {
            _disposed = true;
            try { _queue.CompleteAdding(); } catch { }
            try { _worker.Join(1500); } catch { }
        }
    }
}
