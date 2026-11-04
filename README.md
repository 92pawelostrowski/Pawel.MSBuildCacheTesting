# Pawel.MSBuildCacheTesting

Build 500 .NET 10 projects in a fresh Windows container and measure restore/build
time and MSBuild memory usage with published MSBuildCache, caching disabled, or
MSBuildCache packages you build yourself.

Use Windows 11 24H2 or later, or Windows Server 2025, with Docker already
configured for **local Windows containers**. The image uses Windows Server Core
2025 and process isolation. You need Docker CLI access and internet access for
the first image build and package restore. Running the launcher requires no host
.NET SDK, Visual Studio, or PowerShell 7 installation.

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

Build the packages yourself before running the container. Package authors need
the .NET 10 SDK and .NET Framework 4.7.2 targeting pack, available through Visual
Studio or Build Tools. These tools are not required just to run the launcher.

Keep `version.json` unchanged from its committed contents. Choose a distinct
`OverrideBuildNumberOffset` for each implementation or scenario, for example
`1000` for one and `2000` for another, and use the same offset for both packages.
Nerdbank.GitVersioning adds the offset to the Git version height: the package
version still includes the configured prerelease label and, on feature branches,
the Git SHA. This provides distinct scenario versions without changing source
files; it does not force an arbitrary full version string. Do not override
`PackageVersion`, which Nerdbank.GitVersioning replaces.

An uncommitted change to `version.json` can reset the version height to zero,
which prevents the offset from applying. If you intentionally change that file,
commit the change before building; pushing that commit is unnecessary.

From `R:\git\MSBuildCache`, run these commands. Choose a fresh output directory
for each scenario so old package versions cannot be selected accidentally.
The projects automatically create packages during the build.

```powershell
dotnet build .\src\Local\Microsoft.MSBuildCache.Local.csproj -c Release -p:TargetFrameworks=net472 -p:SignType=Test -p:OverrideBuildNumberOffset=1000 -p:PackageOutputPath=R:\MSBuildCachePackages\scenario-1000
dotnet build .\src\SharedCompilation\Microsoft.MSBuildCache.SharedCompilation.csproj -c Release -p:TargetFrameworks=net472 -p:SignType=Test -p:OverrideBuildNumberOffset=1000 -p:PackageOutputPath=R:\MSBuildCachePackages\scenario-1000
```

Then, from this testing repository, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-docker.ps1 -MSBuildCachePackageDirectory 'R:\MSBuildCachePackages\scenario-1000'
```

The directory must contain exactly one `Microsoft.MSBuildCache.Local` package
and one `Microsoft.MSBuildCache.SharedCompilation` package with matching versions.
Other package IDs, such as Common or Azure packages, are ignored. Do not combine
`-MSBuildCachePackageDirectory` with `-CacheMode`; local mode always enables caching.

The package directory is mounted read-only. The selected pair is copied into
the results' `local-packages\` folder and restored from a private file feed in
the fresh container. Packages are used as supplied; the launcher does not build
MSBuildCache. It verifies that the loaded plugin and helper DLL hashes match
the packages. The default cache universe is derived from both whole-package
SHA256 hashes, covering their managed and native contents.

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
| Local packages | `LocalMSBuildCache\Local\` |
| Disabled | Cache is unused |

Run the same command again to measure a build using that cache. Reuse the same
`.nupkg` files to keep the same local cache universe; changed package hashes
select a new universe.
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
| `local-packages\` (local mode) | Copied package pair, versions and hashes in `manifest.json`, and restore configuration |

Memory includes MSBuild workers and compilers. Private bytes measure private
allocated memory; summed working sets may count shared pages more than once.
Two-second samples can miss short spikes. These metrics do not isolate the
plugin's retained managed heap.

The launcher prefers the `windows-containers` Docker context when it exists;
otherwise it uses the current context. It never changes the active context.
Use `-DockerContext <name>` to select another local Windows engine explicitly.

## Options and troubleshooting

Append `-MaxCpuCount <number>` to change parallelism from the default of two
workers. `-CacheDirectory` and `-ResultsDirectory` accept alternative local paths.
Use a separate cache folder when comparing plugin versions.
`-Configuration Debug` changes the workload configuration; supplied plugin
packages are used as built.

Builds and runs use Docker's default networking. Configure DNS or proxy settings
in Docker if its containers cannot download tools or packages.

## Workload and optional checks

The graph has 20 layers of 25 projects, 4,750 direct project references, and
499 libraries plus one verification application. Implicit transitive references
are disabled. Generated code consumes every declared reference; the application
must produce `395719275`.

The SDK is pinned to `10.0.403`, Traversal to `4.1.82`, and
`Microsoft.MSBuildCache.Local` and `Microsoft.MSBuildCache.SharedCompilation` to
`0.1.340-preview` in published mode. Local mode uses the supplied packages
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
