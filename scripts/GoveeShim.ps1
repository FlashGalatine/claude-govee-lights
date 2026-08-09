<#
.SYNOPSIS
    Dot-source this to get a working GoveeAPI.dll client in Windows PowerShell 5.1.

.DESCRIPTION
    Two things must be true before GoveeAPI.dll works in a host process:

    1. Its 14 sibling assemblies must be loadable. Solved by eager preload -
       NOT by an AssemblyResolve handler written in PowerShell, which recurses
       into the PowerShell engine and kills the process with an uncatchable
       StackOverflowException.

    2. The bindingRedirect from GoveeAPI.dll.config must be honoured. The CLR only
       reads the *application's* config, never a library's, so powershell.exe
       ignores it. TouchSocket asks for System.Runtime.CompilerServices.Unsafe
       4.0.4.1 while the folder ships 6.0.0.0; without the redirect the receive
       callback throws inside ReadOnlySpan<T>, the pipe response is never recorded,
       and every DoRequest times out with code 4000.

       We supply the redirect with an AssemblyResolve handler compiled in C# via
       Add-Type. Because it is compiled code that only consults a dictionary of
       already-loaded assemblies, it cannot re-enter the PowerShell engine and
       cannot recurse.

    A real .NET Framework app solves (2) properly with an App.config instead.

.EXAMPLE
    . .\GoveeShim.ps1
    $g = New-GoveeClient
    $g.Devices()
    $g.Color('Glide Hexa Pro Desk', 255, 0, 0)
#>

$script:GoveeDir = 'C:\Program Files\Govee\Govee Desktop\GoveeAPI'
$script:GoveeDll = Join-Path $script:GoveeDir 'GoveeAPI.dll'

if (-not ('GoveeShim.Resolver' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

namespace GoveeShim {
    // Stands in for the bindingRedirect in GoveeAPI.dll.config. Compiled C#, so it
    // never re-enters the PowerShell engine - which is what made the equivalent
    // PowerShell handler blow the stack.
    public static class Resolver {
        static readonly Dictionary<string, Assembly> _byName =
            new Dictionary<string, Assembly>(StringComparer.OrdinalIgnoreCase);
        static string _dir;
        static bool _installed;

        public static List<string> Loaded = new List<string>();

        public static void Install(string goveeDir) {
            if (_installed) return;
            _dir = goveeDir;

            // Eager preload: get every sibling into the AppDomain up front.
            foreach (var file in Directory.GetFiles(_dir, "*.dll")) {
                try {
                    var asm = Assembly.LoadFrom(file);
                    _byName[asm.GetName().Name] = asm;
                    Loaded.Add(asm.GetName().Name + " " + asm.GetName().Version);
                } catch { /* native or already-loaded; ignore */ }
            }

            AppDomain.CurrentDomain.AssemblyResolve += OnResolve;
            _installed = true;
        }

        static Assembly OnResolve(object sender, ResolveEventArgs args) {
            // Dictionary lookup only. No LoadFrom, no recursion, no I/O.
            string simple = new AssemblyName(args.Name).Name;

            Assembly hit;
            if (_byName.TryGetValue(simple, out hit)) return hit;

            // Anything already in the AppDomain is fair game too - this is the
            // version-agnostic match that makes 6.0.0.0 satisfy a 4.0.4.1 request.
            foreach (var asm in AppDomain.CurrentDomain.GetAssemblies()) {
                if (string.Equals(asm.GetName().Name, simple, StringComparison.OrdinalIgnoreCase)) {
                    _byName[simple] = asm;
                    return asm;
                }
            }
            return null;
        }
    }
}
'@ -Language CSharp
}

function Initialize-GoveeShim {
    [CmdletBinding()] param([string] $GoveeDir = $script:GoveeDir)
    [GoveeShim.Resolver]::Install($GoveeDir)
    [GoveeShim.Resolver]::Loaded
}

function New-GoveeClient {
    <#
      Builds the ConnectGovee object graph by hand.

      InitConnect cannot be used: its IL hardcodes PipeClient(".", "GoveePipe"),
      and Govee Desktop 2.40.50 only creates "GoveeDesktopPipe". We construct the
      same graph against the pipe that exists. A side effect is that the API GUID
      is never validated, because that check lived in the code path we skip.
    #>
    [CmdletBinding()] param([string] $PipeName = 'GoveeDesktopPipe')

    Initialize-GoveeShim | Out-Null

    $asm  = [System.Reflection.Assembly]::LoadFrom($script:GoveeDll)
    $NP=[System.Reflection.BindingFlags]::NonPublic; $PB=[System.Reflection.BindingFlags]::Public
    $IN=[System.Reflection.BindingFlags]::Instance;  $ST=[System.Reflection.BindingFlags]::Static
    $any = $NP -bor $PB -bor $IN; $anyS = $any -bor $ST

    $tGovee = $asm.GetType('GoveeAPI.ConnectGovee')
    $tPipe  = $asm.GetType('GoveeAPI.PipeClient')
    $tDev   = $asm.GetType('GoveeAPI.ConnectDevices')

    $pipe = $tPipe.GetConstructor($any, $null, @([string],[string]), $null).Invoke(@('.', $PipeName))
    $np   = $tPipe.GetProperty('clientPipe', $anyS).GetValue($null)
    if (-not $np) { throw "Pipe '$PipeName' did not connect." }

    $devs = $tDev.GetConstructor($any, $null, @($tPipe), $null).Invoke(@($pipe))
    $api  = [System.Activator]::CreateInstance($tGovee)
    $tGovee.GetField('<pipeClient>k__BackingField', $any).SetValue($api, $pipe)
    $tGovee.GetField('connectDevices', $any).SetValue($api, $devs)

    # InitConnect finishes by priming the device cache; do the same.
    $task = $tDev.GetMethod('GetAllDeciceInfo', $any).Invoke($devs, @())
    if ($task -is [System.Threading.Tasks.Task]) { [void]$task.Wait(15000) }

    $client = [pscustomobject]@{
        Api        = $api
        Type       = $tGovee
        PipeClient = $pipe
        Devices    = $devs
        PipeName   = $PipeName
        Online     = $np.Online
    }

    $call = { param($m, $a) $this.Type.GetMethod($m).Invoke($this.Api, $a) }
    $client | Add-Member -MemberType ScriptMethod -Name Invoke      -Value $call
    $client | Add-Member -MemberType ScriptMethod -Name DevicesJson -Value { $this.Invoke('GetDeviceBaseInfo', @()) }
    $client | Add-Member -MemberType ScriptMethod -Name DeviceList  -Value {
        $raw = $this.Invoke('GetDeviceBaseInfo', @())
        if ("$raw".Trim() -match '^\d+$') { throw "GetDeviceBaseInfo returned code $raw" }
        $p = $raw | ConvertFrom-Json
        if ($p -is [array]) { $p } elseif ($p.data) { @($p.data) } else { @($p) }
    }
    $client | Add-Member -MemberType ScriptMethod -Name Switch     -Value { param($n,$on)      $this.Invoke('DeviceSwitchControl',     @([string]$n,[int]$on)) }
    $client | Add-Member -MemberType ScriptMethod -Name Razer      -Value { param($n,$on)      $this.Invoke('DeviceRZSwitchControl',   @([string]$n,[int]$on)) }
    $client | Add-Member -MemberType ScriptMethod -Name Brightness -Value { param($n,$b)       $this.Invoke('DeviceBrightnessControl', @([string]$n,[int]$b)) }
    $client | Add-Member -MemberType ScriptMethod -Name Color      -Value { param($n,$r,$g,$b) $this.Invoke('DeviceColorControl',      @([string]$n,[int]$r,[int]$g,[int]$b)) }
    $client | Add-Member -MemberType ScriptMethod -Name Segments   -Value { param($n,$csv,$gr) $this.Invoke('DeviceSegmentsColor',     @([string]$n,[string]$csv,[int]$gr)) }

    return $client
}
