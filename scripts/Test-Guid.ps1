<#
.SYNOPSIS
    Fast single-purpose check: does this GUID make InitConnect succeed?

.EXAMPLE
    .\Test-Guid.ps1 -Guid 1234abcd-...
    .\Test-Guid.ps1 -Guid 1234abcd-... -Save
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Guid,
    [string] $DllPath = 'C:\Program Files\Govee\Govee Desktop\GoveeAPI\GoveeAPI.dll',
    [switch] $Save    # on success, write the GUID to Govee-API-GUID.txt
)

$ErrorActionPreference = 'Stop'
$Guid = $Guid.Trim().Trim('"',"'")

$parsed = [guid]::Empty
if (-not [guid]::TryParse($Guid, [ref] $parsed)) {
    Write-Host "  Not a syntactically valid GUID: '$Guid'" -ForegroundColor Red
    exit 1
}
# Note: Govee's GUIDs are NOT RFC 4122 conformant - the variant nibble is often
# outside 8-b. That is normal and is not a transcription error. Do not "fix" it.

# GoveeShim installs the binding redirect that GoveeAPI.dll needs. Without it every
# call times out after ~6s and reports 1001, which reads as a bad GUID and is not.
. (Join-Path $PSScriptRoot 'GoveeShim.ps1')
Initialize-GoveeShim | Out-Null

$type = [System.Reflection.Assembly]::LoadFrom($DllPath).GetType('GoveeAPI.ConnectGovee')
$api  = [System.Activator]::CreateInstance($type)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r  = $type.GetMethod('InitConnect').Invoke($api, @([string]$Guid))
$sw.Stop()

Write-Host ''
Write-Host "  InitConnect -> $r  (in $($sw.ElapsedMilliseconds) ms)" -ForegroundColor White

switch ($r) {
    0 {
        Write-Host '  SUCCESS - this GUID works.' -ForegroundColor Green
        $devices = $type.GetMethod('GetDeviceBaseInfo').Invoke($api, @())
        Write-Host ''
        Write-Host '  Devices:' -ForegroundColor Cyan
        # The wire format exposes IsLANOn - the DTO's IsUdpOnline/IsOn/IsRzOn properties
        # are never serialized, so asking for them yields blank columns.
        ($devices | ConvertFrom-Json) | Format-Table -AutoSize Name, SkuType, SegmentNums, IsLANOn |
            Out-String | Write-Host
        if ($Save) {
            $out = Join-Path (Split-Path $PSScriptRoot -Parent) 'Govee-API-GUID.txt'
            [System.IO.File]::WriteAllText($out, $Guid)
            Write-Host "  Saved to $out" -ForegroundColor Green
        }
    }
    100  { Write-Host '  Pipe write denied - Govee Desktop is running ELEVATED. Restart it normally.' -ForegroundColor Red }
    1001 { Write-Host "  Rejected. At ~$($sw.ElapsedMilliseconds) ms this is a round trip that came back unusable:" -ForegroundColor Red
           Write-Host '  the GUID is wrong, or Settings > API is off.' -ForegroundColor Red }
    1    { Write-Host '  Govee Desktop is not running.' -ForegroundColor Red }
    default { Write-Host "  Unexpected code $r - see docs/API-NOTES.md" -ForegroundColor Red }
}
