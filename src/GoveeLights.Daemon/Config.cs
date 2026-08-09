using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    public class DeviceConfig
    {
        public string Name { get; set; }
        public bool Enabled { get; set; } = true;
        public int Segments { get; set; } = 0;      // 0 = discover from GetDeviceBaseInfo
        public int BrightnessCap { get; set; } = 100;
        public bool Animate { get; set; } = true;
        public bool ManageRazerSwitch { get; set; } = true;
    }

    public class StateStyle
    {
        public string Color { get; set; }
        public string Effect { get; set; }          // solid | breathe | pulse | blink | chase | comet
        public double Hz { get; set; } = 0.6;
        public int Brightness { get; set; } = -1;   // -1 = leave brightness alone
    }

    public class RenderConfig
    {
        public int TickMs { get; set; } = 40;               // 25 fps
        public int MinDeviceIntervalMs { get; set; } = 40;
        public int MaxCallsPerSecGlobal { get; set; } = 90;
        public int KeepaliveSeconds { get; set; } = 30;
        public int TransitionMs { get; set; } = 200;
        public int RgbQuantize { get; set; } = 3;           // skip sends below this delta
    }

    public class QuietHours
    {
        public bool Enabled { get; set; } = false;
        public string Start { get; set; } = "23:30";
        public string End { get; set; } = "08:00";
    }

    public class DaemonConfig
    {
        public bool Enabled { get; set; } = true;
        public string ApiGuid { get; set; } = "";
        public string GoveeDllPath { get; set; } =
            @"C:\Program Files\Govee\Govee Desktop\GoveeAPI\GoveeAPI.dll";
        public int Port { get; set; } = 17321;
        public string LogLevel { get; set; } = "INFO";
        public int IdleShutdownMinutes { get; set; } = 20;
        public int SessionTtlMinutes { get; set; } = 30;

        /// <summary>Docs say 1 = gradient on; the internal field is named _gradientOffSkus,
        /// implying the opposite. Both return 0, so this is exposed for visual tuning.</summary>
        public int IsGradientOff { get; set; } = 1;

        public RenderConfig Render { get; set; } = new RenderConfig();
        public List<DeviceConfig> Devices { get; set; } = new List<DeviceConfig>();
        public Dictionary<string, StateStyle> States { get; set; } = new Dictionary<string, StateStyle>();
        public Dictionary<string, string> ToolClassMap { get; set; } = new Dictionary<string, string>();

        public string RestColor { get; set; } = "#FFD9A0";
        public int RestBrightness { get; set; } = 60;
        /// <summary>What to do when the last session ends: rest | off | hold.
        /// The API cannot read a device's current colour, so a true restore is impossible.</summary>
        public string OnSessionEnd { get; set; } = "rest";

        public QuietHours QuietHours { get; set; } = new QuietHours();

        // ---- loading -------------------------------------------------------------

        public static string DefaultDir =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClaudeGovee");

        public static string DefaultPath => Path.Combine(DefaultDir, "config.json");

        public static DaemonConfig Load(string path, out string error)
        {
            error = null;
            try
            {
                if (!File.Exists(path)) { error = "not found"; return null; }
                var text = File.ReadAllText(path);
                var ser = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
                var cfg = ser.Deserialize<DaemonConfig>(text);
                if (cfg == null) { error = "deserialized to null"; return null; }
                cfg.Normalize();
                return cfg;
            }
            catch (Exception ex) { error = ex.Message; return null; }
        }

        public void Save(string path)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            var ser = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
            File.WriteAllText(path, Prettify(ser.Serialize(this)));
        }

        void Normalize()
        {
            if (Render == null) Render = new RenderConfig();
            if (Devices == null) Devices = new List<DeviceConfig>();
            if (States == null) States = new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);
            if (ToolClassMap == null) ToolClassMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (QuietHours == null) QuietHours = new QuietHours();
            if (Render.TickMs < 10) Render.TickMs = 10;
            if (Port <= 0 || Port > 65535) Port = 17321;
        }

        public LogLevel ParsedLogLevel()
        {
            LogLevel l;
            return Enum.TryParse(LogLevel ?? "INFO", true, out l) ? l : GoveeLights.LogLevel.Info;
        }

        public bool InQuietHours(DateTime now)
        {
            if (QuietHours == null || !QuietHours.Enabled) return false;
            TimeSpan s, e;
            if (!TimeSpan.TryParse(QuietHours.Start, out s)) return false;
            if (!TimeSpan.TryParse(QuietHours.End, out e)) return false;
            var t = now.TimeOfDay;
            // Windows that wrap past midnight are the normal case here.
            return s <= e ? (t >= s && t < e) : (t >= s || t < e);
        }

        /// <summary>Minimal pretty-printer so the on-disk config stays hand-editable.
        /// JavaScriptSerializer emits everything on one line.</summary>
        static string Prettify(string json)
        {
            var sb = new System.Text.StringBuilder();
            int indent = 0; bool inStr = false, esc = false;
            foreach (var c in json)
            {
                if (esc) { sb.Append(c); esc = false; continue; }
                if (c == '\\' && inStr) { sb.Append(c); esc = true; continue; }
                if (c == '"') { inStr = !inStr; sb.Append(c); continue; }
                if (inStr) { sb.Append(c); continue; }

                switch (c)
                {
                    case '{': case '[':
                        sb.Append(c).Append('\n').Append(new string(' ', ++indent * 2)); break;
                    case '}': case ']':
                        sb.Append('\n').Append(new string(' ', --indent * 2)).Append(c); break;
                    case ',':
                        sb.Append(c).Append('\n').Append(new string(' ', indent * 2)); break;
                    case ':':
                        sb.Append(": "); break;
                    default:
                        sb.Append(c); break;
                }
            }
            return sb.ToString();
        }
    }
}
