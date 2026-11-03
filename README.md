# Pawel.MSBuildCacheTesting

A generated, real .NET build graph for functional and memory testing of
Microsoft.MSBuildCache. The initial baseline references the published plugin but
keeps caching disabled on every build.

- 500 C# projects: 499 libraries and one verification application.
- 20 layers of 25 projects. Each project above the first layer references 10
  projects in the preceding layer: 4,750 project-to-project references.
- `dirs.proj` builds every project using Microsoft.Build.Traversal and MSBuild
  static graph mode. Including the traversal entry point, the graph has 501 nodes.
- Implicit transitive project references are disabled. The internal graph has
  5,250 edges: 4,750 declared project references plus 500 traversal references.
- Generated code consumes every declared dependency. Cached values avoid
  exponential runtime work when dependencies are shared.
- The build checks all 500 primary assemblies and runs the verification app.

## Pinned baseline

| Component | Version |
| --- | --- |
| .NET SDK / target framework | `10.0.403` / `net10.0` |
| Microsoft.Build.Traversal | `4.1.82` |
| Microsoft.MSBuildCache.Local | `0.1.340-preview` |

`0.1.340-preview` was the latest published Local package when this baseline was
prepared on 3 November 2026. Its version is pinned in `Directory.Packages.props`
so a future package release does not silently change the baseline.

`MSBuildCacheEnabled=false` prevents registration of `ProjectCachePlugin`. The
build verifies this for all projects before compilation and records the evaluated
configuration in `plugin-state.json`. The SharedCompilation helper package is not
included in this disabled baseline.

The published Local plugin has Windows native dependencies. Successful Linux
baseline builds demonstrate that the **disabled** package can be referenced;
they do not demonstrate that enabled plugin caching works on Linux. Enabling and
testing the plugin is a later step.

## Docker build: Windows or Linux host

Only Docker with Linux containers is required. The pinned SDK and PowerShell are
provided by the image; the host does not need the .NET SDK. Windows uses the
PowerShell launcher; Linux can use the Bash launcher without host PowerShell.

Windows, from PowerShell 7:

```powershell
pwsh -NoProfile -File ./scripts/build-docker.ps1
```

Linux:

```bash
./build-docker.sh
```

Both default to Release, two MSBuild workers, and a memory sample every two
seconds. To change the worker limit or interval:

```powershell
pwsh -NoProfile -File ./scripts/build-docker.ps1 -MaxCpuCount 4 -SampleSeconds 3
```

```bash
./build-docker.sh --max-cpu-count 4 --sample-seconds 3
```

The Docker image contains a source snapshot. Compilation runs at container
startup, not in a cached Docker build layer. Every invocation performs a fresh
restore and build. Host `bin`, `obj`, and `artifacts` directories are excluded
from the image, keeping Windows and Linux intermediate files separate.

Each invocation saves results under `artifacts/docker/<run-id>/`. Set
`-ResultsDirectory <path>` in PowerShell or `--results-directory <path>` in Bash
to choose an explicit location. Only the result directory is mounted into the
container. On a Linux host, the container runs with the calling user's UID/GID.

### Memory reporting is always enabled

The container prints readings throughout restore, compilation, and verification:

```text
[memory 00:12] working set    824.5 MiB | container total   1024.0 MiB | process RSS    910.2 MiB | peak working set    824.5 MiB
```

This is an example of the output format, not a benchmark result. The measurements
cover the whole container, including MSBuild workers and compilers.

- **Working set:** cgroup memory usage minus inactive file cache, similar to the
  working-set value reported by container monitoring tools.
- **Container total:** memory usage including file cache.
- **Process RSS:** summed resident memory of container processes; shared pages
  can be counted more than once.
- **Peak working set:** the largest working-set sample. Short spikes between
  samples can be missed. The summary also records the kernel's container-total
  peak where the cgroup interface provides it.

Memory sampling cannot be disabled through the launchers. Build failures still
produce a final memory sample and summary, and return a failing exit code.
These metrics describe total build memory, not the plugin's retained managed
heap specifically. Docker image download/build time is outside the measured run.

Each results directory contains:

| File | Contents |
| --- | --- |
| `console.log` | Live build output and readable memory samples |
| `memory.csv` | Timestamps, elapsed seconds, and memory readings in bytes |
| `memory-summary.json` | Exit code, sampling interval, and memory peaks |
| `build.binlog` | MSBuild binary log |
| `build.log` | Restore/build console output |
| `build-summary.json` | Verified project count, graph size, SDK, and plugin state |
| `plugin-state.json` | Evaluated plugin property and package/item configuration |
| `verification.log` | Verification application's result |

## Native build

Install the exact SDK from `global.json` and PowerShell 7. Run on Windows or Linux:

```powershell
pwsh -NoProfile -File ./build.ps1
```

The Linux `./build.sh` wrapper calls the same PowerShell script. Native builds
write logs to `artifacts/logs/native/`; the periodic memory sampler is part of the
Docker build. Use `-Configuration Debug` or `-MaxCpuCount 4` with either launcher
when required.

The core build command is:

```text
dotnet msbuild dirs.proj -restore -graphBuild -maxCpuCount:2 -nodeReuse:false -property:Configuration=Release -property:MSBuildCacheEnabled=false
```

The build script also checks generated-file consistency, validates all 500
assemblies, checks the evaluated plugin configuration, and executes Project0499.
The generated application's expected value is `395719275`.

## Generated workload

All projects and sources are checked in. Generating them is not required to build.
`workload.json` records every project, dependency, expected value, and output path.

```powershell
# Check that the committed workload matches the generator; changes nothing.
pwsh -NoProfile -File ./scripts/generate.ps1 -VerifyOnly

# Regenerate after an intentional generator change.
pwsh -NoProfile -File ./scripts/generate.ps1
```

The generator is deterministic and uses no random seeds, timestamps, or external
packages. It refuses unexpected files in the generated source tree rather than
deleting them. Ordinary build outputs are centralized under `artifacts/`.

This first baseline exercises a substantial compilation graph. Strong-fingerprint
observation workloads, cache-hit/miss scenarios, and comparisons between plugin
versions can be added on top of it later.
