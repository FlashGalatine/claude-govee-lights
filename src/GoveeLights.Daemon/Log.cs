using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    public enum LogLevel { Debug = 0, Info = 1, Warn = 2, Error = 3, Fatal = 4 }

    /// <summary>
    /// JSONL logger: one self-describing object per line, daily files, size capped.
    /// Every Govee API call is recorded here with its duration and result code, which
    /// is how rate limits get tuned after the fact.
    /// </summary>
    public static class Log
    {
        static readonly object _gate = new object();
        static readonly JavaScriptSerializer _json = new JavaScriptSerializer();
        static string _dir;
        static string _currentPath;
        static DateTime _currentDate = DateTime.MinValue;
        static StreamWriter _writer;

        const long MaxBytes = 10L * 1024 * 1024;
        const int KeepDays = 7;

        public static LogLevel Level = LogLevel.Info;
        public static bool AlsoConsole = false;

        public static void Init(string dir)
        {
            _dir = dir;
            Directory.CreateDirectory(_dir);
            Prune();
        }

        public static void Debug(string evt, string msg = null, object data = null) => Write(LogLevel.Debug, evt, msg, data);
        public static void Info(string evt, string msg = null, object data = null) => Write(LogLevel.Info, evt, msg, data);
        public static void Warn(string evt, string msg = null, object data = null) => Write(LogLevel.Warn, evt, msg, data);
        public static void Error(string evt, string msg = null, object data = null) => Write(LogLevel.Error, evt, msg, data);
        public static void Fatal(string evt, string msg = null, object data = null) => Write(LogLevel.Fatal, evt, msg, data);

        public static void Exception(string evt, Exception ex)
        {
            // Unwrap AggregateException - the interesting failure is always inside.
            var ae = ex as AggregateException;
            if (ae != null && ae.InnerExceptions.Count > 0) ex = ae.InnerExceptions[0];

            Write(LogLevel.Error, evt, ex.Message, new Dictionary<string, object>
            {
                { "type", ex.GetType().FullName },
                { "stack", ex.StackTrace }
            });
        }

        static void Write(LogLevel lvl, string evt, string msg, object data)
        {
            if (lvl < Level) return;

            var rec = new Dictionary<string, object>
            {
                { "ts", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture) },
                { "lvl", lvl.ToString().ToUpperInvariant() },
                { "evt", evt }
            };
            if (!string.IsNullOrEmpty(msg)) rec["msg"] = msg;

            // Merge a dictionary payload into the record so fields stay top-level and
            // greppable rather than nested under "data".
            var dict = data as IDictionary<string, object>;
            if (dict != null) { foreach (var kv in dict) rec[kv.Key] = kv.Value; }
            else if (data != null) rec["data"] = data;

            string line;
            try { line = _json.Serialize(rec); }
            catch { line = "{\"ts\":\"?\",\"lvl\":\"ERROR\",\"evt\":\"log_serialize_failed\"}"; }

            lock (_gate)
            {
                try
                {
                    EnsureWriter();
                    if (_writer != null) { _writer.WriteLine(line); _writer.Flush(); }
                }
                catch { /* logging must never take the daemon down */ }

                if (AlsoConsole)
                {
                    try { Console.WriteLine("{0} {1,-5} {2} {3}", rec["ts"], rec["lvl"], evt, msg); } catch { }
                }
            }
        }

        static void EnsureWriter()
        {
            if (_dir == null) return;
            var today = DateTime.Now.Date;

            if (_writer != null && today == _currentDate)
            {
                // Roll early if the current file has grown past the cap.
                try { if (new FileInfo(_currentPath).Length < MaxBytes) return; }
                catch { return; }
            }

            if (_writer != null) { try { _writer.Dispose(); } catch { } _writer = null; }

            _currentDate = today;
            var base_ = Path.Combine(_dir, "daemon-" + today.ToString("yyyyMMdd") + ".log");
            var path = base_;
            int n = 1;
            while (File.Exists(path) && new FileInfo(path).Length >= MaxBytes)
                path = Path.Combine(_dir, "daemon-" + today.ToString("yyyyMMdd") + "." + (n++) + ".log");

            _currentPath = path;
            _writer = new StreamWriter(new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
        }

        static void Prune()
        {
            try
            {
                var cutoff = DateTime.Now.Date.AddDays(-KeepDays);
                foreach (var f in Directory.GetFiles(_dir, "daemon-*.log"))
                {
                    try { if (File.GetLastWriteTime(f).Date < cutoff) File.Delete(f); }
                    catch { }
                }
            }
            catch { }
        }
    }
}
