# Pawel.MSBuildCacheTesting

Build 500 .NET 10 projects in a fresh Windows container and measure restore/build
time and MSBuild memory usage with the published MSBuildCache plugin enabled.

Use Windows 11 24H2 or later, or Windows Server 2025, with Docker already
configured for **local Windows containers**. The image uses Windows Server Core
2025 and process isolation. You need Docker CLI access and internet access for
the first image build and package restore. No host .NET SDK, Visual Studio, or
PowerShell 7 installation is required.

From the repository directory, run this in Windows PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-docker.ps1
```

The script builds the image, runs the workload, prints build time and memory
readings every two seconds, and verifies the resulting application. The first
image build downloads and installs the SDK and Visual Studio Build Tools and
can take some time; later invocations reuse those image layers. Image setup and
output verification are excluded from the measured restore/build time and memory.
The script temporarily keeps Windows awake during image setup and execution,
then releases that request. Display and power-plan settings are preserved.

Each invocation starts a fresh container with fresh build outputs. The ignored
host folder `LocalMSBuildCache\` is mounted at `C:\MSBuildCache` and survives
between runs. Run the same command again to measure a build using that cache.
Actual plugin hit and miss counts are printed. Run builds sequentially because
the local cache requires exclusive access.
Cache output placement is synchronous so directory observations see complete
dependency outputs before cache lookup continues.

Results are saved under `artifacts\docker\<run-id>\`:

| File | Contents |
| --- | --- |
| `build-summary.json` | `restoreBuildSeconds`, cache hits/misses, and verification result |
| `memory.csv` | Timestamped memory samples from the actual MSBuild process and descendants |
| `memory-summary.json` | Sampled peak private bytes and summed working sets |
| `build.log`, `build.binlog`, `console.log` | Build diagnostics and console output |

Memory includes MSBuild workers and compilers. Private bytes measure private
allocated memory; summed working sets may count shared pages more than once.
Two-second samples can miss short spikes. These metrics do not isolate the
plugin's retained managed heap.

The launcher prefers the `windows-containers` Docker context when it exists;
otherwise it uses the current context. It never changes the active context.
Use `-DockerContext <name>` to select another local Windows engine explicitly.

## Options and troubleshooting

Append `-CacheMode Disabled` for a control build, or `-MaxCpuCount <number>` to
change parallelism from the default of two workers. `-CacheDirectory` and
`-ResultsDirectory` accept alternative local paths. Use a separate cache folder
when comparing plugin versions.

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
`0.1.340-preview`. The image supplies Git, PowerShell 7, and x64 Visual Studio
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
