<#
.SYNOPSIS
    Discover Govee devices on the LAN over UDP, bypassing Govee Desktop entirely.

.DESCRIPTION
    The bundled GoveeAPI.dll is broken against Govee Desktop 2.40.50 (it connects to a
    named pipe, "GoveePipe", that the app no longer creates - see docs/API-NOTES.md).

    Fortunately the same IL dump showed that the shim's own device commands are just
    Govee's documented LAN API: 'turn', 'brightness', 'colorwc', 'razer', sent as UDP
    JSON. We can speak that protocol directly and cut out the middleman.

    Protocol:
      discovery : send  {"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}
                        to multicast 239.255.255.250:4001
                  listen on UDP 4002 for replies
      control   : send to <deviceIp>:4003

    Requires "LAN Control" enabled per-device in the Govee Home mobile app.
#>
[CmdletBinding()]
param(
    [int] $ListenSeconds = 5,
    [switch] $Quiet          # suppress the per-packet trace
)

$ErrorActionPreference = 'Stop'

$MULTICAST = '239.255.255.250'
$CMD_PORT  = 4001   # where devices listen for scan
$RESP_PORT = 4002   # where devices reply
$CTRL_PORT = 4003   # where devices listen for control

function Write-Ok  ($t) { Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Write-Bad ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Write-Info($t) { Write-Host "  [INFO] $t" -ForegroundColor Gray }

Write-Host ''
Write-Host '=== Govee LAN discovery ===' -ForegroundColor Cyan

# Bind the response port. Govee Desktop may already hold it, so do not demand
# exclusive use - both processes can receive the multicast replies.
$listener = New-Object System.Net.Sockets.UdpClient
$listener.Client.SetSocketOption(
    [System.Net.Sockets.SocketOptionLevel]::Socket,
    [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
$listener.ExclusiveAddressUse = $false
try {
    $listener.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $RESP_PORT)))
    Write-Ok "Listening on UDP $RESP_PORT"
} catch {
    Write-Bad "Could not bind UDP $RESP_PORT : $($_.Exception.Message)"
    Write-Bad 'Another process may hold it exclusively. Close Govee Desktop and retry.'
    exit 1
}

# Send the scan request out of every IPv4 interface - multicast routing on a
# multi-homed box (VPNs, Hyper-V switches, WSL) otherwise picks the wrong one.
$scan  = '{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}'
$bytes = [System.Text.Encoding]::UTF8.GetBytes($scan)
$dest  = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($MULTICAST), $CMD_PORT)

$nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' }

$sent = 0
foreach ($nic in $nics) {
    foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
        if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
        try {
            $s = New-Object System.Net.Sockets.UdpClient
            $s.Client.SetSocketOption(
                [System.Net.Sockets.SocketOptionLevel]::Socket,
                [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
            $s.Client.Bind((New-Object System.Net.IPEndPoint($ua.Address, 0)))
            [void]$s.Send($bytes, $bytes.Length, $dest)
            $s.Close()
            if (-not $Quiet) { Write-Info "scan sent via $($ua.Address) ($($nic.Name))" }
            $sent++
        } catch {
            if (-not $Quiet) { Write-Info "skip $($ua.Address): $($_.Exception.Message)" }
        }
    }
}
Write-Ok "Scan broadcast on $sent interface(s). Collecting for $ListenSeconds s..."

# Collect replies.
$devices = @{}
$deadline = (Get-Date).AddSeconds($ListenSeconds)
while ((Get-Date) -lt $deadline) {
    if ($listener.Available -gt 0) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        try {
            $data = $listener.Receive([ref]$remote)
            $text = [System.Text.Encoding]::UTF8.GetString($data)
            if (-not $Quiet) { Write-Host "    <- $($remote.Address): $text" -ForegroundColor DarkGray }
            $obj = $text | ConvertFrom-Json
            $d   = $obj.msg.data
            if ($d -and $d.device) { $devices[$d.device] = $d }
        } catch { }
    } else {
        Start-Sleep -Milliseconds 100
    }
}
$listener.Close()

Write-Host ''
if ($devices.Count -eq 0) {
    Write-Bad 'No devices replied.'
    Write-Host ''
    Write-Info 'Checklist:'
    Write-Info '  1. Enable "LAN Control" per device in the Govee Home MOBILE app'
    Write-Info '     (Device > Settings > LAN Control). It is off by default.'
    Write-Info '  2. The PC and the lights must be on the same subnet / VLAN.'
    Write-Info '  3. Allow inbound UDP 4002 for this process in Windows Firewall.'
    Write-Info '  4. Some APs block multicast between wireless clients ("AP isolation").'
    exit 1
}

Write-Ok "Discovered $($devices.Count) device(s):"
Write-Host ''
$devices.Values | ForEach-Object {
    [pscustomobject]@{
        Sku        = $_.sku
        Device     = $_.device
        IP         = $_.ip
        HwVersion  = $_.bleVersionHard
        SwVersion  = $_.bleVersionSoft
        WifiHw     = $_.wifiVersionHard
        WifiSw     = $_.wifiVersionSoft
    }
} | Format-Table -AutoSize | Out-String | Write-Host

Write-Host '  Control port is UDP ' -NoNewline -ForegroundColor Gray
Write-Host $CTRL_PORT -ForegroundColor White
Write-Info 'Next: scripts\Test-GoveeLan.ps1 -Ip <address> to drive one of these.'
Write-Host ''
