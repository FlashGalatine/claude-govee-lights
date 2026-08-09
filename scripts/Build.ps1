<#
.SYNOPSIS
    Build the daemon and stage it into dist\daemon\.

.DESCRIPTION
    Requires only the .NET SDK. net48 reference assemblies come from the targeting
    pack already present on this machine; Microsoft.NETFramework.ReferenceAssemblies
    would serve the same purpose on a machine without it.
#>
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')] [string] $Configuration = 'Release',
    [switch] $Restart
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$proj = Join-Path $root 'src\GoveeLights.Daemon\GoveeLights.Daemon.csproj'
$dist = Join-Path $root 'dist\daemon'

Write-Host "Building $Configuration..." -ForegroundColor Cyan

# The daemon locks its own exe while running.
$running = Get-Process GoveeLightsDaemon -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "  Stopping running daemon (PID $($running.Id))" -ForegroundColor Gray
    try { Invoke-RestMethod -Uri 'http://127.0.0.1:17321/shutdown' -Method Post -TimeoutSec 2 | Out-Null } catch { }
    Start-Sleep -Milliseconds 800
    Get-Process GoveeLightsDaemon -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 400
}

& dotnet build $proj -c $Configuration -v minimal --nologo
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

$binDir = Join-Path $root "src\GoveeLights.Daemon\bin\$Configuration\net48"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
Copy-Item (Join-Path $binDir '*') -Destination $dist -Recurse -Force

# The bindingRedirect config is not optional - without it every Govee call times out.
$cfg = Join-Path $dist 'GoveeLightsDaemon.exe.config'
if (-not (Test-Path $cfg)) {
    throw "GoveeLightsDaemon.exe.config missing from output. Without its bindingRedirect the daemon cannot talk to Govee."
}

Write-Host "  Staged to $dist" -ForegroundColor Green

if ($Restart) {
    Start-Process -FilePath (Join-Path $dist 'GoveeLightsDaemon.exe') -WindowStyle Hidden
    Start-Sleep -Seconds 4
    try {
        $h = Invoke-RestMethod -Uri 'http://127.0.0.1:17321/health' -TimeoutSec 3
        Write-Host "  Daemon up: govee=$($h.goveeState) state=$($h.state) pid=$($h.pid)" -ForegroundColor Green
    } catch {
        Write-Host "  Daemon did not answer /health" -ForegroundColor Red
    }
}
