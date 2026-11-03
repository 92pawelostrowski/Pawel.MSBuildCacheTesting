# Pawel.MSBuildCacheTesting

Build 500 .NET 10 projects in a fresh Windows container and measure restore/build
time and MSBuild memory usage with published MSBuildCache, caching disabled, or
your own MSBuildCache source checkout.

Use Windows 11 24H2 or later, or Windows Server 2025, with Docker already
configured for **local Windows containers**. The image uses Windows Server Core
2025 and process isolation. You need Docker CLI access and internet access for
the first image build and package restore. No host .NET SDK, Visual Studio, or
PowerShell 7 installation is required.

## Choose a build

Run one of these commands from the repository directory in Windows PowerShell.
All three use the same workload, fresh build outputs, and memory sampler.

### 1. Published MSBuildCache

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-docker.ps1
```

### 2. MSBuildCache disabled

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-docker.ps1 -CacheMode Disabled
```

This control run verifies that no cache plugin is registered and no cache-hit
statistics are produced. The same target-time file workload still executes.

### 3. Your local MSBuildCache implementation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-docker.ps1 -MSBuildCacheRepository 'R:\git\MSBuildCache'
```

Replace the required `-MSBuildCacheRepository` value with your checkout's path.
Do not combine it with `-CacheMode`; local mode always enables caching.

The checkout is mounted read-only. The container copies its current source,
including uncommitted edits and new source files, into a disposable build folder.
Existing `bin`, `obj`, `artifacts`, Git history, and editor folders are excluded.
It then builds fresh `Microsoft.MSBuildCache.Local` and
`Microsoft.MSBuildCache.SharedCompilation` NuGet packages in Release for the
`net472` target used by the container's full-framework MSBuild, using the
checkout's package feed. This adds no host tool requirements and
does not change the checkout. Automatic .NET Framework and .NET SDK framework
packs come directly from nuget.org, avoiding the Azure feed's authenticated
upstream cache.

The workload restores those exact packages from a private file feed inside the
container, using the exact version produced by the checkout's versioning targets.
The disposable Git snapshot can produce a different version number than a host
build; its source snapshot and DLL hashes identify the implementation being tested.
Each fresh container has a fresh NuGet package cache. The run verifies that the loaded plugin and helper
DLL hashes match the newly built packages. A changed implementation gets a
different default cache universe, derived from both DLL hashes.

Local plugin compilation happens **before** measurement, so the metrics still
cover only the 500-project restore/build. Source compilation and package details
are saved in `local-packages\` under the run's results directory.

## Measurements and repeat runs

The script builds the image, runs the workload, prints build time and memory
readings every two seconds, and verifies the resulting application. The first
image build downloads and installs the SDK and Visual Studio Build Tools and
can take some time; later invocations reuse those image layers. Image setup and
output verification are excluded from the measured restore/build time and memory.
The script temporarily keeps Windows awake during image setup and execution,
then releases that request. Display and power-plan settings are preserved.

Each invocation starts a fresh container with fresh build outputs. The ignored
host cache folder is mounted at `C:\MSBuildCache` and survives between runs:

| Mode | Default host cache |
| --- | --- |
| Published | `LocalMSBuildCache\` |
| Local source | `LocalMSBuildCache\Local\` |
| Disabled | Cache is unused |

Run the same command again to measure a build using that cache. Local mode
rebuilds the packages each time; unchanged DLLs keep the same cache universe.
Actual plugin hit and miss counts are printed. Run builds sequentially because
the local cache requires exclusive access.
Cache output placement is synchronous so directory observations see complete
dependency outputs before cache lookup continues.

Results are saved under `artifacts\docker\<run-id>\`:

| File | Contents |
| --- | --- |
| `build-summary.json` | Implementation, package/DLL identity, `restoreBuildSeconds`, cache hits/misses, and verification result |
| `memory.csv` | Timestamped memory samples from the actual MSBuild process and descendants |
| `memory-summary.json` | Sampled peak private bytes and summed working sets |
| `build.log`, `build.binlog`, `console.log` | Build diagnostics and console output |
| `local-packages\` (local mode) | Fresh packages, build log, hashes/source snapshot in `manifest.json`, and restore configuration |

Memory includes MSBuild workers and compilers. Private bytes measure private
allocated memory; summed working sets may count shared pages more than once.
Two-second samples can miss short spikes. These metrics do not isolate the
plugin's retained managed heap.

The launcher prefers the `windows-containers` Docker context when it exists;
otherwise it uses the current context. It never changes the active context.
Use `-DockerContext <name>` to select another local Windows engine explicitly.

## Options and troubleshooting

Append `-MaxCpuCount <number>` to change parallelism from the default of two
workers. `-CacheDirectory` and
`-ResultsDirectory` accept alternative local paths. Use a separate cache folder
when comparing plugin versions.
`-Configuration Debug` changes the workload configuration; local plugin packages
are always built in Release, matching the published plugin's optimization mode.

Builds and runs use the project-owned NAT network `pawel-msbuildcachetesting`,
with DNS inferred from active host IPv4 adapters. If container downloads cannot
resolve names, supply reachable IPv4 resolvers with `-DnsServers`. Use
`-NetworkName` if the default name conflicts with an existing network. Only an
idle network owned by this repository is refreshed when its DNS settings change.

## Workload and optional checks

The graph has 20 layers of 25 projects, 4,750 direct project references, and
499 libraries plus one verification application. Implicit transitive references
are disabled. Generated code consumes every declared reference; the application
must produce `395719275`.

The SDK is pinned to `10.0.403`, Traversal to `4.1.82`, and
`Microsoft.MSBuildCache.Local` and `Microsoft.MSBuildCache.SharedCompilation` to
`0.1.340-preview` in published mode. Local mode builds the supplied checkout
instead. The image supplies Git, PowerShell 7, and x64 Visual Studio
Build Tools because the plugin requires full-framework MSBuild and file-access
reporting.

During target execution, each project reads shared settings, enumerates 1,000
shared directory members, and probes a marker unique to that project. These
inputs live in `workload-inputs\`; deliberate edits are preserved. Cached
observation sidecars are checked against current inputs after each build.
Append `-ValidateFingerprints` to additionally inspect every project's actual
strong-fingerprint dump after measurement.

For an optional cold/warm/replay campaign, run
`pwsh -NoProfile -File .\scripts\test-cache.ps1`. This helper requires host
PowerShell 7 and saves results under `artifacts\tests\<run-id>\`.

Generated projects and sources are checked in. Maintainers can check them with
`pwsh -NoProfile -File .\scripts\generate.ps1 -VerifyOnly`, or regenerate them
by omitting `-VerifyOnly`.
