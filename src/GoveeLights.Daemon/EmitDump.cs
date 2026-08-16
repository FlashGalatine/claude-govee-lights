using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Threading;

namespace GoveeLights
{
    /// <summary>
    /// Runs the real Renderer against a recording transport in real time and prints
    /// every wire call with a timestamp, then exits. No hardware, no port, no config
    /// dir. Consumed by scripts/Test-Emits.ps1.
    ///
    /// This exists because the daemon's worst failure mode is invisible at the frame
    /// level: Effects computed perfect chase frames for weeks while the strip showed
    /// nothing, because emission TIMING - transition bursts at 25/s, segment writes
    /// landing inside the DreamView engagement window - is what the hardware actually
    /// reacts to. --dump-frames cannot see timing; this can.
    ///
    /// Output: a "# emits ..." header, then "ms|call|device|detail" rows. Script
    /// progress is marked inline as "ms|force|StateName" rows so tests can anchor
    /// assertions to state entries without guessing at sleep jitter.
    /// </summary>
    public static class EmitDump
    {
        class Recorder : IGoveeTransport
        {
            readonly Stopwatch _sw;
            readonly List<string> _rows;
            readonly List<GoveeDevice> _devices;

            public Recorder(Stopwatch sw, List<string> rows, int segments)
            {
                _sw = sw;
                _rows = rows;
                _devices = new List<GoveeDevice>
                {
                    new GoveeDevice { Name = "T", SkuType = "TEST", SegmentNums = segments, IsLANOn = 1 }
                };
            }

            void Row(string call, string device, string detail)
            {
                lock (_rows)
                    _rows.Add(_sw.Elapsed.TotalMilliseconds.ToString("0", CultureInfo.InvariantCulture)
                        + "|" + call + "|" + device + "|" + detail);
            }

            public bool Connected => true;
            public IReadOnlyList<GoveeDevice> Devices => _devices;
            public void EnsureConnected() { }
            public void Switch(string name, bool on) => Row("switch", name, on ? "on" : "off");
            public void Razer(string name, bool on) => Row("razer", name, on ? "on" : "off");
            public void Brightness(string name, int pct) => Row("brightness", name, pct.ToString(CultureInfo.InvariantCulture));
            public void Color(string name, int r, int g, int b) => Row("color", name, new Rgb(r, g, b).ToHex());
            public void Segments(string name, string csv, int gradientOff) => Row("segments", name, csv + "|grad=" + gradientOff);
            public void RefreshDevices() => Row("refresh", "", "");
            public void Mark(string call, string detail) => Row(call, detail, "");
        }

        public static int Run(string[] args)
        {
            // No Log.Init in this mode; keep the renderer's Info chatter out of the
            // machine-readable stream entirely.
            Log.AlsoConsole = false;
            Log.Level = LogLevel.Warn;

            var cfgPath = Arg(args, "--config", null);
            if (string.IsNullOrEmpty(cfgPath)) { Console.Error.WriteLine("--dump-emits needs --config"); return 2; }
            string err;
            var cfg = DaemonConfig.Load(cfgPath, out err);
            if (cfg == null) { Console.Error.WriteLine("bad --config: " + err); return 2; }

            var script = Arg(args, "--script", "");
            var segments = ArgInt(args, "--segments", 10);
            var resyncAt = ArgInt(args, "--resync-at", -1);
            if (segments < 1) segments = 1;

            var steps = new List<KeyValuePair<Activity, int>>();
            foreach (var part in script.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var bits = part.Split(':');
                Activity a;
                int ms;
                if (bits.Length != 2
                    || !Enum.TryParse(bits[0].Trim(), true, out a)
                    || !int.TryParse(bits[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out ms)
                    || ms < 0)
                {
                    Console.Error.WriteLine("bad --script entry: " + part + " (want State:ms)");
                    return 2;
                }
                steps.Add(new KeyValuePair<Activity, int>(a, ms));
            }

            var sw = Stopwatch.StartNew();
            var rows = new List<string>();
            var rec = new Recorder(sw, rows, segments);
            var renderer = new Renderer(rec, new SessionStore(), () => cfg, new StyleStore());
            renderer.SyncDevices();

            var resyncDone = resyncAt < 0;
            foreach (var step in steps)
            {
                rec.Mark("force", step.Key.ToString());
                // Hold well past the window so the state never decays to Offline
                // mid-script; the next Force simply overrides it.
                renderer.Force(step.Key, step.Value + 10000);
                var end = sw.Elapsed.TotalMilliseconds + step.Value;
                while (sw.Elapsed.TotalMilliseconds < end)
                {
                    if (!resyncDone && sw.Elapsed.TotalMilliseconds >= resyncAt)
                    {
                        rec.Mark("resync", "");
                        renderer.SyncDevices();
                        resyncDone = true;
                    }
                    Thread.Sleep(5);
                }
            }
            renderer.Dispose();

            var w = Console.Out;
            w.WriteLine("# emits segments=" + segments + " script=" + script);
            lock (rows) foreach (var r in rows) w.WriteLine(r);
            w.Flush();
            return 0;
        }

        static string Arg(string[] args, string name, string dflt)
        {
            for (int i = 0; i < args.Length - 1; i++)
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            return dflt;
        }

        static int ArgInt(string[] args, string name, int dflt)
        {
            int v;
            return int.TryParse(Arg(args, name, null), NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : dflt;
        }
    }
}
