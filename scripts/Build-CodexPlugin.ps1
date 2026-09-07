<#
.SYNOPSIS
    Build a self-contained Codex plugin at dist\codex\govee-lights.

.DESCRIPTION
    Combines the Codex template with the shared daemon, operational scripts, and
    themes. Builds into a fresh staging directory so packaging does not stop or
    overwrite the daemon used by Claude Code. No credentials or local configuration
    are included, and no Codex settings or marketplaces are changed.

.PARAMETER SkipBuild
    Package the existing src\GoveeLights.Daemon\bin\Release\net48 build instead.
    Use only when that Release build already contains the current source changes.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-CodexPlugin.ps1
#>
[CmdletBinding()]
param([switch] $SkipBuild)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$template = Join-Path $root 'codex\govee-lights'
$project = Join-Path $root 'src\GoveeLights.Daemon\GoveeLights.Daemon.csproj'
$outputParent = Join-Path $root 'dist\codex'
$destination = Join-Path $outputParent 'govee-lights'
$stagingParent = Join-Path $outputParent ('.staging-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $stagingParent 'govee-lights'

function Assert-GeneratedPath([string] $Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    $boundary = $outputParent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the generated Codex output: $absolute"
    }

    # Reject junctions/symlinks in existing ancestors before creating, moving, or
    # deleting anything. A textual path inside the repo must also stay there on disk.
    $ancestor = $absolute
    while ($ancestor -and $ancestor -ne $root) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Generated output must not contain a junction or symbolic link: $ancestor"
            }
        }
        $ancestor = Split-Path $ancestor -Parent
    }
    if ($ancestor -ne $root) { throw "Generated output must be inside the repository: $absolute" }
}

function Remove-GeneratedDirectory([string] $Path) {
    Assert-GeneratedPath $Path
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $links = @(Get-ChildItem -LiteralPath $Path -Force -Recurse |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count) { throw "Refusing to remove generated output containing a junction or symbolic link: $Path" }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Copy-PackageFile([string] $Source, [string] $RelativePath) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required package input is missing: $Source"
    }
    $target = Join-Path $stage $RelativePath
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $target -Force
}

$templateFiles = @('.codex-plugin\plugin.json', 'hooks\hooks.json', 'skills\govee\SKILL.md')
$runtimeScripts = @(
    'Codex-Hook.ps1', 'Ensure-Daemon.ps1', 'Govee-Cli.ps1', 'GoveeShim.ps1',
    'Test-Guid.ps1', 'Scan-GoveeLan.ps1', 'Demo-Govee.ps1'
)
foreach ($relative in $templateFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $template $relative) -PathType Leaf)) {
        throw "Codex template is incomplete: $relative is missing from $template"
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $template '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
$claudeManifest = Get-Content -LiteralPath (Join-Path $root '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
[xml] $projectXml = Get-Content -LiteralPath $project -Raw
$projectVersion = [string] $projectXml.Project.PropertyGroup.Version
if ($manifest.name -ne 'govee-lights') { throw 'The Codex manifest name must match its govee-lights folder.' }
if (-not $manifest.version -or $manifest.version -ne $claudeManifest.version -or $manifest.version -ne $projectVersion) {
    throw "Version mismatch: Codex=$($manifest.version), Claude=$($claudeManifest.version), daemon=$projectVersion."
}

# Validate structured inputs before spending time on a build or changing output.
$hooks = Get-Content -LiteralPath (Join-Path $template 'hooks\hooks.json') -Raw | ConvertFrom-Json
Assert-GeneratedPath $destination
Assert-GeneratedPath $stagingParent
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    foreach ($relative in $templateFiles) {
        Copy-PackageFile (Join-Path $template $relative) $relative
    }
    foreach ($name in $runtimeScripts) {
        Copy-PackageFile (Join-Path $root "scripts\$name") "scripts\$name"
    }
    Copy-PackageFile (Join-Path $root 'docs\EFFECTS.md') 'docs\EFFECTS.md'
    Copy-PackageFile (Join-Path $root 'LICENSE') 'LICENSE'
    foreach ($theme in Get-ChildItem -LiteralPath (Join-Path $root 'themes') -Filter '*.json' -File) {
        Get-Content -LiteralPath $theme.FullName -Raw | ConvertFrom-Json | Out-Null
        Copy-PackageFile $theme.FullName "themes\$($theme.Name)"
    }

    foreach ($eventHooks in $hooks.hooks.PSObject.Properties) {
        foreach ($group in $eventHooks.Value) {
            foreach ($hook in $group.hooks) {
                if ($hook.type -ne 'command' -or $hook.command -notmatch 'scripts[\\/]Codex-Hook\.ps1') {
                    throw "Codex $($eventHooks.Name) hook must invoke the packaged scripts/Codex-Hook.ps1 command."
                }
            }
        }
    }
    $skillPath = Join-Path $stage 'skills\govee\SKILL.md'
    foreach ($reference in [regex]::Matches((Get-Content -LiteralPath $skillPath -Raw), '\[[^\]]+\]\(([^)#]+)(?:#[^)]*)?\)')) {
        $link = $reference.Groups[1].Value
        if ($link -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') { continue }
        $resolvedLink = [IO.Path]::GetFullPath((Join-Path (Split-Path $skillPath -Parent) $link))
        $stageBoundary = $stage + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedLink.StartsWith($stageBoundary, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $resolvedLink)) {
            throw "The Govee skill references a file outside the package or a missing file: $link"
        }
    }

    $daemonOutput = Join-Path $stage 'dist\daemon'
    New-Item -ItemType Directory -Path $daemonOutput -Force | Out-Null
    if ($SkipBuild) {
        $releaseOutput = Join-Path $root 'src\GoveeLights.Daemon\bin\Release\net48'
        if (-not (Test-Path -LiteralPath (Join-Path $releaseOutput 'GoveeLightsDaemon.exe') -PathType Leaf)) {
            throw 'No Release build exists. Run this script without -SkipBuild to build the daemon.'
        }
        # Only compiled runtime outputs, including satellite assemblies and their
        # relative folders. Never copy source, obj, local config, or credential files.
        foreach ($file in Get-ChildItem -LiteralPath $releaseOutput -File -Recurse) {
            if ($file.Name -notmatch '(?i)(\.exe$|\.dll$|\.pdb$|\.(exe|dll)\.config$|\.deps\.json$|\.runtimeconfig(\.dev)?\.json$)') { continue }
            $relative = $file.FullName.Substring($releaseOutput.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
            Copy-PackageFile $file.FullName "dist\daemon\$relative"
        }
    } else {
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            throw 'The .NET SDK is required. Install it, or use -SkipBuild with an existing Release build.'
        }
        Write-Host 'Building the Release daemon for Codex...' -ForegroundColor Cyan
        & dotnet build $project --configuration Release --output $daemonOutput --verbosity minimal --nologo
        if ($LASTEXITCODE -ne 0) { throw "Daemon build failed with exit code $LASTEXITCODE." }
    }

    $exe = Join-Path $daemonOutput 'GoveeLightsDaemon.exe'
    $configPath = Join-Path $daemonOutput 'GoveeLightsDaemon.exe.config'
    foreach ($required in @($exe, $configPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required daemon output is missing: $required" }
    }
    $binaryVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion -split '\+')[0]
    if ($binaryVersion -ne $projectVersion) {
        throw "Daemon build version $binaryVersion does not match $projectVersion. Run without -SkipBuild."
    }

    # Binding redirects are essential for Govee's dependency set; successful
    # compilation alone does not prove that the staged daemon can load it.
    [xml] $builtConfig = Get-Content -LiteralPath $configPath -Raw
    [xml] $sourceConfig = Get-Content -LiteralPath (Join-Path $root 'src\GoveeLights.Daemon\App.config') -Raw
    foreach ($dependency in $sourceConfig.configuration.runtime.assemblyBinding.dependentAssembly) {
        $name = [string] $dependency.assemblyIdentity.name
        $builtDependency = @($builtConfig.configuration.runtime.assemblyBinding.dependentAssembly |
            Where-Object { $_.assemblyIdentity.name -eq $name })
        if ($builtDependency.Count -ne 1 -or
            $builtDependency[0].bindingRedirect.newVersion -ne $dependency.bindingRedirect.newVersion -or
            $builtDependency[0].bindingRedirect.oldVersion -ne $dependency.bindingRedirect.oldVersion) {
            throw "Daemon output is missing the required binding redirect for $name."
        }
    }

    # Replace only this generated package after every input and the build validate.
    # Starting with a clean directory prevents old package contents being shipped.
    $existingExe = Join-Path $destination 'dist\daemon\GoveeLightsDaemon.exe'
    if (Test-Path -LiteralPath $existingExe -PathType Leaf) {
        try {
            $probe = [IO.File]::Open($existingExe, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $probe.Dispose()
        } catch {
            throw "Cannot replace the existing Codex package: its daemon executable is in use or not writable. Stop that packaged daemon before rebuilding. $($_.Exception.Message)"
        }
    }
    Remove-GeneratedDirectory $destination
    Assert-GeneratedPath $stage
    Assert-GeneratedPath $destination
    Move-Item -LiteralPath $stage -Destination $destination
    Write-Host "Codex plugin $($manifest.version) staged at $destination" -ForegroundColor Green
} finally {
    Remove-GeneratedDirectory $stagingParent
}
