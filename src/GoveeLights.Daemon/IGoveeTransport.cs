using System.Collections.Generic;

namespace GoveeLights
{
    /// <summary>What the renderer needs from the Govee side. GoveeClient is the real
    /// implementation; EmitDump substitutes a recorder so emission TIMING is testable
    /// without hardware. The 2026-08-15 camera investigation showed this is the class
    /// of bug frames can never surface: Effects computed perfect chase frames for weeks
    /// while the strip rendered nothing, because transition bursts and writes inside
    /// the DreamView engagement window are wire-timing phenomena. See Test-Emits.ps1.</summary>
    public interface IGoveeTransport
    {
        bool Connected { get; }
        IReadOnlyList<GoveeDevice> Devices { get; }
        void EnsureConnected();
        void Switch(string name, bool on);
        void Razer(string name, bool on);
        void Brightness(string name, int pct);
        void Color(string name, int r, int g, int b);
        void Segments(string name, string csv, int gradientOff);
        void RefreshDevices();
    }
}
