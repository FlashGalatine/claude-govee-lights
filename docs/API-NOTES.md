# Govee Desktop OpenAPI — verified notes

Everything here was confirmed empirically against
`C:\Program Files\Govee\Govee Desktop\GoveeAPI\GoveeAPI.dll` (v1.0.0.1, built 2023-12-06)
by reflection and live calls. Where it contradicts the shipped
`Govee Desktop OpenAPI Instructions.docx`, **this file is right and the DOCX is wrong.**

> That DOCX is Govee's own document and is not redistributed here. Govee provides it
> alongside the Desktop app (Settings ▸ API ▸ View User Guide). This file is an
> independent record of observed behaviour and is self-contained — you do not need the
> original to use or modify this project.

## Actual method signatures

```csharp
Int32  InitConnect(String guidInfo)
String DeviceSwitchControl(String skuName, Int32 isOff)
String DeviceRZSwitchControl(String skuName, Int32 isOff)      // undocumented
String DeviceBrightnessControl(String skuName, Int32 brightness)
String DeviceColorControl(String skuName, Int32 r, Int32 g, Int32 b)
String GetDeviceBaseInfoByName(String skuName)
String GetDeviceBaseInfo()
String DeviceSegmentsColor(String skuName, String colorInfo, Int32 isGradientOff)
```

### Corrections to the DOCX

| DOCX says | Reality |
|---|---|
| `GetDeviceBasenfo(skuName)` (in both the .NET and Python samples) | **No such method.** It is `GetDeviceBaseInfoByName(String)`. The DOCX body table has it right; only the code samples are typo'd. |
| Control methods return `int` | **They return `String`.** Only `InitConnect` returns `Int32`. Any code written straight from the DOCX breaks on the return type. |
| Device info exposes `IsLANOn` | **Correct** — the DOCX is right here. The `DeviceInfoByThird` *class* has a property called `IsUdpOnline`, but the JSON `GetDeviceBaseInfo` actually emits uses `IsLANOn` (int, 0/1). Trust the wire format, not the DTO. |
| Six methods | **Seven.** `DeviceRZSwitchControl` is undocumented and toggles the Razer/DreamView mode that `DeviceSegmentsColor` silently requires. |
| `isOff` parameter name | Misleading — `0` = Off, `1` = On, per the DOCX body. |

## Type surface

```
public  GoveeAPI.ConnectGovee          // the entry point
public  GoveeAPI.DeviceInfoByThird     // Name, SkuType, SegmentNums, SkuId, Hostname,
                                       // DeviceId, IsUdpOnline, BleVersionSoft, IsRzOn, IsOn
public  GoveeAPI.DeviceReqDto          // + IsOn, IsRZOn, Brightness, RGB, List<Segment> Segments
public  GoveeAPI.Segment               // RankIndex, AreaIndex, Color
public  GoveeAPI.RGB                   // Byte R, G, B
internal GoveeAPI.ConnectDevices
internal GoveeAPI.PipeClient
internal GoveeAPI.PipeSendInfo
internal GoveeAPI.PipeSendResult       // String ExecutionName, String ExecutionResult
```

`DeviceInfoByThird` has **no colour field**, so the current colour of a light cannot be read
back. Restoring a user's previous lighting state is therefore impossible — only
`IsOn` / `IsRzOn` / brightness can be captured and reapplied.

## Transport: it is *not* purely a named pipe

`GoveeAPI.ConnectDevices` holds both:

```
PipeClient Client            // -> \\.\pipe\GoveeDesktopPipe
UdpClient  _uniUdpClient     // + Int32 SEND_UNI_PORT
List<...>  _gradientOffSkus
```

So the pipe is used to talk to Govee Desktop (discovery / state sync), but **colour, switch
and segment commands are sent as UDP from our own process directly to the device on the LAN.**

Consequences:
- Windows Firewall can block the device's inbound UDP reply while the outbound command still
  lands. The symptom is result code **`4000`** ("No response. Please observe the light
  changes") *with the light visibly changing*. Treat `4000` as a soft success, not a failure —
  counting it as an error would trip a circuit breaker on a working setup.
- The PC must be on the same L2 network as the device, and the device's LAN API must be on.

## The DLL is NOT thread-safe

`GoveeAPI.PipeClient` stores its state in **static** fields:

```
static NamedPipeClient      <clientPipe>k__BackingField
static Dictionary<,>        clientResvice
```

Responses are correlated by an `ExecutionName` string key in that shared dictionary. Two
concurrent calls will collide in it, and the failure mode is a response being handed to the
wrong caller — i.e. silently wrong behaviour, not an exception.

**Therefore: exactly one `ConnectGovee` instance, and every call serialized onto one
dedicated worker thread. Never call from an HTTP request thread.** This is non-negotiable.

There is also no cancellation on the pipe round trip, so a hung call needs an external
watchdog rather than a timeout parameter.

## Loading the assembly: do NOT use an AssemblyResolve handler

`GoveeAPI.dll` is .NET Framework 4.x (`ImageRuntimeVersion v4.0.30319`, AnyCPU). Its 14
dependencies live beside it in Program Files, not in the consumer's output directory:

```
GoveeFactoryAPI 1.0.0.0            TouchSocket 2.0.0.0
Newtonsoft.Json 9.0.0.0            TouchSocket.Core 2.0.0.0
System.Text.Json 6.0.0.0           TouchSocket.NamedPipe 2.0.0.0
System.Text.Encodings.Web 6.0.0.0  System.Memory 4.0.1.1
System.Buffers 4.0.3.0             System.Numerics.Vectors 4.1.4.0
System.ValueTuple 4.0.0.0          System.Threading.Tasks.Extensions 4.2.0.1
Microsoft.Bcl.AsyncInterfaces 6.0.0.0
System.Runtime.CompilerServices.Unsafe 6.0.0.0
```

The obvious approach — an `AppDomain.CurrentDomain.AssemblyResolve` handler that calls
`Assembly.LoadFrom` — **crashes the process with an uncatchable StackOverflowException
(exit code 253).** Confirmed twice, including with a re-entrancy-guarded handler: the handler
body itself executes code that triggers further assembly loads, re-entering the handler
faster than the guard can be consulted.

**Working approach: eagerly preload every `*.dll` in the GoveeAPI folder before touching
`ConnectGovee`.** Once all 14 are in the AppDomain the resolve event never fires. All 14 load
cleanly with zero failures.

A consumer must also replicate the bindingRedirect from `GoveeAPI.dll.config` into its **own**
app config — the CLR reads the application's config, never a library's:

```xml
<dependentAssembly>
  <assemblyIdentity name="System.Runtime.CompilerServices.Unsafe"
                    publicKeyToken="b03f5f7f11d50a3a" culture="neutral" />
  <bindingRedirect oldVersion="0.0.0.0-6.0.0.0" newVersion="6.0.0.0" />
</dependentAssembly>
```

## Result codes

| Code | Meaning |
|---|---|
| 0 | Succeeded |
| 1 | Govee Desktop is not running |
| 100 | Program running error |
| 101 | Initialization failure |
| 102 | Device is offline |
| 1001 | API GUID error |
| 1002 | Parameter is empty |
| 1003 | The device does not exist |
| 1010 | Colour value error |
| 1011 | Invalid brightness |
| 4000 | No response (see UDP note above — usually a soft success) |
| 4001 | Failed to send |

### THE root cause: a missing bindingRedirect looks like a bad GUID

This one cost hours, so it is worth stating precisely.

**Symptom.** `InitConnect` returns `1001` ("API GUID error") after a uniform ~6 s, for
*every* input — the correct GUID, a random GUID, all-zeroes, even the empty string (which the
docs say should return `1002`):

```
ours (correct, from the app UI)  -> 1001  (6072 ms)
random valid GUID                -> 1001  (5792 ms)
all zeroes                       -> 1001  (5736 ms)
empty string                     -> 1001  (5731 ms)
```

Identical timing across all inputs means the GUID is never evaluated. `1001` here is a
generic failure, not a credential error.

**Cause.** TouchSocket's pipe *receive callback* constructs a `ReadOnlySpan<T>`, which needs
`System.Runtime.CompilerServices.Unsafe` **4.0.4.1**. The GoveeAPI folder ships **6.0.0.0**,
and `GoveeAPI.dll.config` contains the `bindingRedirect` that reconciles them. **The CLR only
reads the *application's* config, never a library's** — so in any host that lacks the
redirect, the callback throws:

```
System.IO.FileNotFoundException: Could not load file or assembly
'System.Runtime.CompilerServices.Unsafe, Version=4.0.4.1' ...
   at System.ReadOnlySpan`1..ctor(T[] array)
```

The request is sent successfully, the reply arrives, and the handler dies while parsing it.
The response is never recorded, so `PipeClient.DoRequest` waits out its ~5.7 s timeout and
every call fails. `DoRequest` returns `4000` in that state; `InitConnect` reports `1001`.

**Fix.** Supply the redirect in the consuming application (`App.config` for a .NET Framework
exe). With it in place, `InitConnect` returns `0` in ~282 ms and everything works.

**Non-causes** — all of these were investigated and exonerated:
- The API GUID (correct as issued; note Govee's GUIDs are not RFC 4122 conformant — the
  variant nibble can be outside `8`–`b`, which is normal and not a transcription error).
- Settings ▸ API being off.
- The `'GoveePipe'` literal in `InitConnect`. `PipeClient`'s constructor **ignores its
  `pipeName` argument** and hardcodes `GoveeDesktopPipe`, so the stale name is harmless.
- Version skew between the 2023 shim and Govee Desktop 2.40.50.

Because `InitConnect` works once the redirect is present, **use the supported entry point.**
No reflection graft onto `PipeClient` / `ConnectDevices` is necessary.

## Do NOT run Govee Desktop as administrator

The DOCX says "Run the client-side Govee Desktop as an administrator." **Following that advice
breaks the API for any normal client**, and this is measured, not theorised.

When Govee Desktop runs elevated it creates `\\.\pipe\GoveeDesktopPipe` with a DACL that
denies write access to the same user's non-elevated processes:

```
Govee Desktop ELEVATED, client non-elevated:
  Direction In    -> CONNECTED
  Direction Out   -> Access to the path is denied.
  Direction InOut -> Access to the path is denied.
```

The API needs `InOut`. The result is `InitConnect` returning **`100` in ~29 ms** — a fast,
hard failure, distinguishable from the ~6 s timeout described below.

With Govee Desktop running normally, `InOut` connects fine and an unelevated client works.

**Correct arrangement: Govee Desktop non-elevated, daemon non-elevated.** This is also what
makes the plugin installable without a UAC prompt or a scheduled task.

### Distinguishing the two failure modes

| Symptom | Cause |
|---|---|
| `100` in ~30 ms | Pipe write denied — Govee Desktop is running elevated |
| `1001` in ~6 s | Request sent, no usable reply — bad GUID, or API switch off |
| `0` immediately | Working |

## Environment facts

- `\\.\pipe\GoveeDesktopPipe` is openable for **read/write** by a non-elevated same-user
  process **only when Govee Desktop is itself non-elevated** (see above).
- The API GUID is **not persisted anywhere on disk** — not in `%LOCALAPPDATA%\GoveeDesktop`,
  not in the registry. It can only be read from Settings ▸ API in the UI.
- Govee Desktop itself is self-contained .NET 6 — a different runtime from the .NET Framework
  shim it ships.
- Windows PowerShell 5.1 runs on .NET Framework 4.x and can host `GoveeAPI.dll` directly with
  no build step, which makes it the right tool for probing.

## Measured behaviour (all calls returning `0` = success)

### Real device inventory

`GetDeviceBaseInfo()` returns a bare JSON array with exactly four fields per device:

```json
[{"Name":"Glide Hexa Pro Desk","SegmentNums":4,"SkuType":"H6066","IsLANOn":1},
 {"Name":"H619A_E79B","SegmentNums":10,"SkuType":"H619A","IsLANOn":1},
 {"Name":"AC Smart Plug","SegmentNums":10,"SkuType":"H5080","IsLANOn":0},
 {"Name":"Glide Hexa Pro","SegmentNums":16,"SkuType":"H6066","IsLANOn":1},
 {"Name":"H61A0_E78D","SegmentNums":10,"SkuType":"H61A0","IsLANOn":0},
 {"Name":"DreamView G1 Pro","SegmentNums":0,"SkuType":"H604A","IsLANOn":0}]
```

No `IsOn` / `IsRzOn` / `Hostname` on the wire, despite the DTO declaring them. **There is no
way to read back a device's current state** — so restore-on-exit can only mean "apply a
configured resting colour", never "put back what was there".

`Name` is the key used by every control method, despite the parameter being called `skuName`.
Two devices share `SkuType` `H6066` but differ by `Name`, confirming `Name` is the identifier.

**Segment counts must come from this call, not from `device_info.ini`**, which reports a flat
`10` for everything. The truth is `Glide Hexa Pro Desk` = 4 and `Glide Hexa Pro` = 16.

### Latency

Control calls are fire-and-forget UDP sends, not round trips, so they are extremely cheap:

```
GetDeviceBaseInfo   141 ms   (pipe round trip)
InitConnect         282 ms   (pipe round trip)
DeviceColorControl  avg 0.5 ms | p50 0.2 | p95 3.5 | max 4.8   (~2000 calls/sec)
DeviceSwitchControl / Brightness / Segments   12-37 ms first call, then sub-ms
```

Animation is therefore comfortably viable. The binding constraint is **not** our call rate but
what the device and the LAN will tolerate — rate-limit by choice, not by necessity. The
"single animated device, degrade above 80 ms RTT" contingency is unnecessary.

### Return values

All control methods returned the string `"0"` — a bare integer code as text, not
`PipeSendResult` JSON. Parse with `int.TryParse` first; keep the JSON fallback only as a guard.

## Still unresolved

1. `isGradientOff` polarity. The DOCX says `1` = gradient on; the internal field is named
   `_gradientOffSkus`, implying `1` = gradient **off**. Both values return `0`, so only visual
   inspection can settle it.
2. `DeviceRZSwitchControl` polarity (presumed to match `DeviceSwitchControl`: `1` = on).
   Returns `0` either way.
3. Whether a `0` return guarantees the light physically changed. Since the transport is UDP,
   `0` means "sent", not "acknowledged".
