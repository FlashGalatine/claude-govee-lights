using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    public static class Program
    {
        [DllImport("kernel32.dll")] static extern bool AllocConsole();

        static DaemonConfig _cfg;
        static readonly object _cfgGate = new object();
        static GoveeClient _govee;
        static SessionStore _sessions;
        static HookMapper _mapper;
        static Renderer _renderer;
        static MiniHttpServer _http;
        static FileSystemWatcher _watcher;
        static readonly JavaScriptSerializer _json = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
        static readonly DateTime _startedAt = DateTime.UtcNow;
        static readonly ManualResetEventSlim _quit = new ManualResetEventSlim(false);

        static DaemonConfig Cfg() { lock (_cfgGate) return _cfg; }

        [STAThread]
        public static int Main(string[] args)
        {
            var console = args.Any(a => a == "--console");
            if (console) { AllocConsole(); Log.AlsoConsole = true; }

            var dir = DaemonConfig.DefaultDir;
            Directory.CreateDirectory(dir);
            Log.Init(Path.Combine(dir, "logs"));

            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                Log.Fatal("unhandled", (e.ExceptionObject as Exception)?.Message ?? "unknown");
            };

            var configPath = DaemonConfig.DefaultPath;
            string err;
            _cfg = DaemonConfig.Load(configPath, out err);
            if (_cfg == null)
            {
                Log.Warn("config_missing", "writing defaults", new Dictionary<string, object> { { "path", configPath }, { "error", err } });
                _cfg = BuildDefaultConfig();
                try { _cfg.Save(configPath); } catch (Exception ex) { Log.Exception("config_save_failed", ex); }
            }
            Log.Level = _cfg.ParsedLogLevel();

            if (string.IsNullOrWhiteSpace(_cfg.ApiGuid))
            {
                Log.Fatal("no_guid", "config.json has no apiGuid; copy it from Govee Desktop Settings > API");
                if (console) { Console.WriteLine("No apiGuid in " + configPath); Console.ReadKey(); }
                return 2;
            }

            Log.Info("starting", "daemon boot", new Dictionary<string, object>
            {
                { "version", Assembly.GetExecutingAssembly().GetName().Version.ToString() },
                { "port", _cfg.Port },
                { "pid", System.Diagnostics.Process.GetCurrentProcess().Id }
            });

            _sessions = new SessionStore
            {
                Ttl = TimeSpan.FromMinutes(Math.Max(1, _cfg.SessionTtlMinutes))
            };
            _mapper = new HookMapper(_sessions, _cfg.ToolClassMap);
            _govee = new GoveeClient(_cfg.GoveeDllPath, _cfg.ApiGuid);
            _renderer = new Renderer(_govee, _sessions, Cfg);

            // Bind before anything else observable: a second instance must lose here.
            _http = new MiniHttpServer(_cfg.Port, Handle);
            string httpErr;
            if (!_http.Start(out httpErr))
            {
                Log.Warn("bind_failed", httpErr, new Dictionary<string, object> { { "port", _cfg.Port } });
                if (console) Console.WriteLine("Could not bind port " + _cfg.Port + ": " + httpErr);
                // Another daemon already owns the port - that is success, not failure.
                return 0;
            }

            // Device roster needs the API connected first.
            _govee.PostAndWait(() => { }, 100);
            ThreadPool.QueueUserWorkItem(_ =>
            {
                for (int i = 0; i < 40 && !_govee.Connected; i++) Thread.Sleep(250);
                if (_govee.Connected) _renderer.SyncDevices();
                else Log.Warn("no_connect", "Govee did not connect during startup; will retry");
            });

            WatchConfig(configPath);

            Console.CancelKeyPress += (s, e) => { e.Cancel = true; _quit.Set(); };

            // Idle shutdown: exit once nothing has happened for a while, so we are not a
            // permanent background process. SessionStart restarts us instantly.
            var idleLimit = TimeSpan.FromMinutes(Math.Max(1, _cfg.IdleShutdownMinutes));
            while (!_quit.IsSet)
            {
                if (_quit.Wait(5000)) break;
                if (_sessions.Count == 0 && DateTime.UtcNow - _renderer.LastActivityAt > idleLimit)
                {
                    Log.Info("idle_shutdown", "no sessions; exiting");
                    break;
                }
            }

            Shutdown();
            return 0;
        }

        static void Shutdown()
        {
            Log.Info("stopping", "graceful shutdown");
            try { _http?.Dispose(); } catch { }
            try { _renderer?.Dispose(); } catch { }
            // Give queued restore commands a moment to actually leave the process.
            try { _govee?.PostAndWait(() => { }, 1500); } catch { }
            try { _govee?.Dispose(); } catch { }
            try { _watcher?.Dispose(); } catch { }
        }

        // ---- HTTP ------------------------------------------------------------------

        static HttpResponse Handle(HttpRequest req)
        {
            switch (req.Path)
            {
                case "/hook": return OnHook(req);
                case "/health": return OnHealth();
                case "/status": return OnStatus();
                case "/devices": return OnDevices();
                case "/test": return OnTest(req);
                case "/enable": return SetEnabled(true);
                case "/disable": return SetEnabled(false);
                case "/refresh":
                    _govee.RefreshDevices();
                    _govee.Post(() => _renderer.SyncDevices());
                    return HttpResponse.Json("{\"ok\":true}");
                case "/shutdown":
                    ThreadPool.QueueUserWorkItem(_ => { Thread.Sleep(150); _quit.Set(); });
                    return HttpResponse.Json("{\"ok\":true}");
                default:
                    return HttpResponse.Text(404, "no such endpoint");
            }
        }

        /// <summary>
        /// Accepts every hook event. Parses, enqueues, returns 204 immediately.
        ///
        /// This must never touch Govee: http hooks do not support async, so Claude Code
        /// is blocked until we respond. Everything expensive happens on other threads.
        /// </summary>
        static HttpResponse OnHook(HttpRequest req)
        {
            string hint;
            req.Query.TryGetValue("e", out hint);

            try
            {
                var payload = string.IsNullOrEmpty(req.Body)
                    ? new Dictionary<string, object>()
                    : _json.Deserialize<Dictionary<string, object>>(req.Body);

                var evt = Str(payload, "hook_event_name");
                var sid = Str(payload, "session_id");
                var cwd = Str(payload, "cwd");
                var tool = Str(payload, "tool_name");

                Log.Debug("hook", evt, new Dictionary<string, object>
                {
                    { "hint", hint }, { "sessionId", sid }, { "tool", tool }
                });

                _mapper.Handle(evt, hint, sid, cwd, tool);
            }
            catch (Exception ex)
            {
                // A malformed payload must never surface to Claude Code as an error.
                Log.Exception("hook_parse_failed", ex);
            }

            return HttpResponse.NoContent();
        }

        static HttpResponse OnHealth()
        {
            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object>
            {
                { "ok", true },
                { "pid", System.Diagnostics.Process.GetCurrentProcess().Id },
                { "uptimeSec", Math.Round((DateTime.UtcNow - _startedAt).TotalSeconds, 1) },
                { "goveeState", _govee.Connected ? "ready" : "offline" },
                { "state", _renderer.Current.ToString() },
                { "sessions", _sessions.Count }
            }));
        }

        static HttpResponse OnStatus()
        {
            var cfg = Cfg();
            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object>
            {
                { "ok", true },
                { "version", Assembly.GetExecutingAssembly().GetName().Version.ToString() },
                { "uptimeSec", Math.Round((DateTime.UtcNow - _startedAt).TotalSeconds, 1) },
                { "enabled", cfg.Enabled },
                { "quietHours", cfg.InQuietHours(DateTime.Now) },
                { "govee", new Dictionary<string, object>
                    {
                        { "connected", _govee.Connected },
                        { "lastError", _govee.LastError }
                    } },
                { "render", _renderer.Status() },
                { "sessions", _sessions.Snapshot() }
            }));
        }

        static HttpResponse OnDevices()
        {
            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object>
            {
                { "ok", true },
                { "discovered", _govee.Devices.Select(d => (object)new Dictionary<string, object>
                    {
                        { "name", d.Name }, { "sku", d.SkuType },
                        { "segments", d.SegmentNums }, { "lanOn", d.LanOn }
                    }).ToList() },
                { "render", _renderer.Status() }
            }));
        }

        static HttpResponse OnTest(HttpRequest req)
        {
            string stateName = null;
            int hold = 6000;
            try
            {
                if (!string.IsNullOrEmpty(req.Body))
                {
                    var body = _json.Deserialize<Dictionary<string, object>>(req.Body);
                    stateName = Str(body, "state");
                    object h;
                    if (body.TryGetValue("holdMs", out h) && h != null) int.TryParse(h.ToString(), out hold);
                }
            }
            catch { }
            if (string.IsNullOrEmpty(stateName)) req.Query.TryGetValue("state", out stateName);

            Activity a;
            if (!Enum.TryParse(stateName, true, out a))
                return HttpResponse.Text(400, "unknown state '" + stateName + "'. Valid: " +
                    string.Join(", ", Enum.GetNames(typeof(Activity))));

            _renderer.Force(a, hold);
            Log.Info("test_state", a.ToString(), new Dictionary<string, object> { { "holdMs", hold } });
            return HttpResponse.Json("{\"ok\":true,\"state\":\"" + a + "\",\"holdMs\":" + hold + "}");
        }

        static HttpResponse SetEnabled(bool on)
        {
            lock (_cfgGate) _cfg.Enabled = on;
            Log.Info("enabled", on ? "on" : "off");
            return HttpResponse.Json("{\"ok\":true,\"enabled\":" + (on ? "true" : "false") + "}");
        }

        // ---- config hot-reload ------------------------------------------------------

        static void WatchConfig(string path)
        {
            try
            {
                _watcher = new FileSystemWatcher(Path.GetDirectoryName(path), Path.GetFileName(path))
                {
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size,
                    EnableRaisingEvents = true
                };
                DateTime last = DateTime.MinValue;
                _watcher.Changed += (s, e) =>
                {
                    // Editors write in bursts; debounce so we reload once.
                    if ((DateTime.UtcNow - last).TotalMilliseconds < 500) return;
                    last = DateTime.UtcNow;
                    Thread.Sleep(200);

                    string err;
                    var fresh = DaemonConfig.Load(path, out err);
                    if (fresh == null)
                    {
                        Log.Warn("config_reload_failed", err ?? "unknown; keeping previous config");
                        return;
                    }
                    lock (_cfgGate) _cfg = fresh;
                    Log.Level = fresh.ParsedLogLevel();
                    _renderer.SyncDevices();
                    Log.Info("config_reloaded", path);
                };
            }
            catch (Exception ex) { Log.Exception("config_watch_failed", ex); }
        }

        static DaemonConfig BuildDefaultConfig()
        {
            var cfg = new DaemonConfig { States = Palette.Defaults() };

            // Seed the GUID from the repo file if it is sitting next to the exe tree, so a
            // first run works without hand-editing config.json.
            try
            {
                var here = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                for (var d = new DirectoryInfo(here); d != null; d = d.Parent)
                {
                    var f = Path.Combine(d.FullName, "Govee-API-GUID.txt");
                    if (File.Exists(f)) { cfg.ApiGuid = File.ReadAllText(f).Trim(); break; }
                }
            }
            catch { }

            return cfg;
        }

        static string Str(IDictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) && v != null ? v.ToString() : null;
        }
    }
}
