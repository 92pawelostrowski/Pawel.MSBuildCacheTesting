#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidateRange(1, 256)]
    [int] $MaxCpuCount = 2,

    [string] $LogDirectory = '',

    [string] $CacheDirectory = '',

    [ValidateNotNullOrEmpty()]
    [string] $CacheUniverse = 'published-0.1.340-preview-v1',

    [string] $MSBuildPath = '',

    [string] $LocalPackageManifest = '',

    [ValidateSet('Enabled', 'Disabled')]
    [string] $CacheMode = 'Enabled',

    [ValidateRange(-1, 500)]
    [int] $ExpectedHits = -1,

    [ValidateRange(-1, 500)]
    [int] $ExpectedMisses = -1,

    [switch] $MeasureMemory,

    [ValidateRange(1, 3600)]
    [int] $SampleSeconds = 2,

    [switch] $ValidateFingerprints
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$repoRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/')
if (-not $PSBoundParameters.ContainsKey('CacheMode')) {
    $CacheMode = if ($IsWindows) { 'Enabled' } else { 'Disabled' }
}
$cacheEnabled = $CacheMode -eq 'Enabled'
$cacheEnabledText = $cacheEnabled.ToString().ToLowerInvariant()
$pathComparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
$expectedRuntime = if ($IsWindows) { 'Full' } else { 'Core' }
$msbuildPrefixArguments = @()
$cachePackageVersion = '0.1.340-preview'
$cacheImplementation = if ($cacheEnabled) { 'Published' } else { 'Disabled' }
$localPackages = $null
if (-not [string]::IsNullOrWhiteSpace($LocalPackageManifest)) {
    if (-not $cacheEnabled) { throw 'Local packages require caching to be enabled.' }
    $LocalPackageManifest = [IO.Path]::GetFullPath($LocalPackageManifest)
    $localPackages = Get-Content -LiteralPath $LocalPackageManifest -Raw | ConvertFrom-Json
    if ($localPackages.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace($localPackages.packageVersion) -or
        $localPackages.localPluginAssemblySha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $localPackages.sharedCompilationAssemblySha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The local package manifest is invalid.'
    }
    $cachePackageVersion = $localPackages.packageVersion
    $cacheImplementation = 'Local'
}
$summaryPath = $null
$timer = [System.Diagnostics.Stopwatch]::StartNew()

function Assert-NativeSuccess([string] $Operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-FullRepositoryPath([string] $Path) {
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path $repoRoot $Path
    }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-PathsOverlap([string] $First, [string] $Second) {
    return [string]::Equals($First, $Second, $pathComparison) -or
        $First.StartsWith($Second + [System.IO.Path]::DirectorySeparatorChar, $pathComparison) -or
        $Second.StartsWith($First + [System.IO.Path]::DirectorySeparatorChar, $pathComparison)
}

function Remove-FreshBuildOutputs([string[]] $Paths) {
    foreach ($path in $Paths) {
        $absolutePath = [System.IO.Path]::GetFullPath($path).TrimEnd('\', '/')
        if (-not $absolutePath.StartsWith($repoRoot + [System.IO.Path]::DirectorySeparatorChar, $pathComparison)) {
            throw "Refusing to clean a path outside the repository: $absolutePath"
        }

        # Check existing ancestors too: a junction at artifacts must never redirect a cleanup.
        $ancestor = $absolutePath
        while (-not [string]::Equals($ancestor, $repoRoot, $pathComparison)) {
            if (Test-Path -LiteralPath $ancestor) {
                $item = Get-Item -LiteralPath $ancestor -Force
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing to clean through a reparse point: $ancestor"
                }
            }
            $ancestor = [System.IO.Path]::GetDirectoryName($ancestor)
        }

        if (-not (Test-Path -LiteralPath $absolutePath)) {
            continue
        }
        $children = @(Get-ChildItem -LiteralPath $absolutePath -Recurse -Force)
        foreach ($item in $children) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to clean a tree containing a reparse point: $($item.FullName)"
            }
        }
        foreach ($file in $children | Where-Object { -not $_.PSIsContainer }) {
            $file.IsReadOnly = $false
        }
        Write-Host "Cleaning build outputs: $absolutePath"
        Remove-Item -LiteralPath $absolutePath -Recurse -Force
    }
}

function ConvertTo-MSBuildPropertyValue([string] $Value) {
    return $Value.Replace('%', '%25').Replace(';', '%3B').Replace(',', '%2C').Replace('"', '%22')
}

function Get-MSBuildCapabilities([string] $Executable) {
    $assemblyPath = Join-Path ([System.IO.Path]::GetDirectoryName($Executable)) 'Microsoft.Build.dll'
    $quotedPath = $assemblyPath.Replace("'", "''")
    $probe = @"
`$ErrorActionPreference = 'Stop'
`$assembly = [System.Reflection.Assembly]::LoadFrom('$quotedPath')
`$type = `$assembly.GetType('Microsoft.Build.Experimental.FileAccess.FileAccessData')
[ordered]@{
    fileAccessData = (`$null -ne `$type)
    enumerationPattern = (`$null -ne `$type -and `$null -ne `$type.GetProperty('EnumeratePattern'))
} | ConvertTo-Json -Compress
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($probe))
    $pwshExecutable = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $probeText = (& $pwshExecutable -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded | Out-String)
    Assert-NativeSuccess 'Probing the native MSBuild file-access API'
    return $probeText | ConvertFrom-Json
}

function Assert-WorkloadSidecars($Manifest) {
    $workload = $Manifest.strongFingerprintWorkload
    if (-not $workload.enabled) {
        throw 'The generated manifest must enable the target-time input workload.'
    }

    $settingsPath = Join-Path $repoRoot $workload.settingsPath
    $membersDirectory = Join-Path $repoRoot $workload.membersDirectory
    [string[]] $settingLines = @()
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        # Match ReadLinesFromFile: trim NUL, space and tab at each end, then skip empty lines.
        $trimCharacters = [char[]] @([char]0, [char]' ', [char]"`t")
        $settingLines = @(
            foreach ($line in [IO.File]::ReadAllLines($settingsPath)) {
                $trimmed = $line.Trim($trimCharacters)
                if ($trimmed.Length -gt 0) { "setting=$trimmed" }
            }
        )
    }
    [string[]] $memberLines = @()
    if (Test-Path -LiteralPath $membersDirectory -PathType Container) {
        $memberLines = @(Get-ChildItem -LiteralPath $membersDirectory -File -Filter '*.member' | ForEach-Object { "member=$($_.Name)" })
    }
    [Array]::Sort($memberLines, [StringComparer]::Ordinal)

    $verified = 0
    foreach ($project in $Manifest.projects) {
        $sidecarRelativePath = $workload.sidecarPath.Replace('{projectName}', $project.name).Replace('{configuration}', $Configuration)
        $sidecarPath = Join-Path $repoRoot $sidecarRelativePath
        if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
            throw "The build did not produce the target-time workload sidecar: $sidecarPath"
        }
        $markerPath = Join-Path $repoRoot $workload.markerPath.Replace('{projectName}', $project.name)
        $markerExists = (Test-Path -LiteralPath $markerPath).ToString().ToLowerInvariant()
        [string[]] $actual = [IO.File]::ReadAllLines($sidecarPath)
        $expectedLength = 3 + $settingLines.Count + $memberLines.Count
        if ($actual.Length -ne $expectedLength -or
            $actual[0] -cne "project=$($project.name)" -or
            $actual[1] -cne "marker=$markerExists" -or
            $actual[2] -cne "membercount=$($memberLines.Count)") {
            throw "The workload sidecar does not match the current input state: $sidecarPath"
        }
        [string[]] $actualSettings = @($actual | Where-Object { $_.StartsWith('setting=', [StringComparison]::Ordinal) })
        [string[]] $actualMembers = @($actual | Where-Object { $_.StartsWith('member=', [StringComparison]::Ordinal) })
        [Array]::Sort($actualMembers, [StringComparer]::Ordinal)
        if ($actualSettings.Count -ne $settingLines.Count -or $actualMembers.Count -ne $memberLines.Count -or
            -not [StringComparer]::Ordinal.Equals(($actualSettings -join "`n"), ($settingLines -join "`n")) -or
            -not [StringComparer]::Ordinal.Equals(($actualMembers -join "`n"), ($memberLines -join "`n"))) {
            throw "The workload sidecar settings or directory members differ from the current inputs: $sidecarPath"
        }
        $verified++
    }
    if ($verified -ne 500) {
        throw "Expected 500 verified workload sidecars; found $verified."
    }
    return $verified
}

function Assert-ObservedStrongFingerprints($Manifest, [string] $PluginLogDirectory) {
    $workload = $Manifest.strongFingerprintWorkload
    $projectsByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($project in $Manifest.projects) {
        $projectsByPath.Add($project.path.Replace('\', '/'), $project)
    }
    $validated = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $settingsPath = $workload.settingsPath.Replace('\', '/')
    $membersPath = $workload.membersDirectory.Replace('\', '/')
    $markersPath = $workload.markerDirectory.Replace('\', '/')
    $membersDirectory = Join-Path $repoRoot $workload.membersDirectory
    $memberCount = if (Test-Path -LiteralPath $membersDirectory -PathType Container) {
        @(Get-ChildItem -LiteralPath $membersDirectory -File -Filter '*.member').Count
    }
    else { 0 }

    foreach ($dumpFile in Get-ChildItem -LiteralPath $PluginLogDirectory -Filter fingerprint.json -File -Recurse) {
        $dump = Get-Content -LiteralPath $dumpFile.FullName -Raw | ConvertFrom-Json -Depth 64
        $project = $null
        if ($null -eq $dump.weak) { continue }
        foreach ($entry in $dump.weak.entries) {
            $description = ([string] $entry.description).Replace('\', '/')
            if ($projectsByPath.ContainsKey($description)) {
                $project = $projectsByPath[$description]
                break
            }
        }
        if ($null -eq $project) { continue }
        if ($validated.Contains($project.name)) {
            throw "Multiple fingerprint dumps identify $($project.name); expected one build configuration per project."
        }
        if ($null -eq $dump.strong) {
            throw "No strong fingerprint was recorded for $($project.name): $($dumpFile.FullName)"
        }
        foreach ($entry in $dump.weak.entries) {
            $description = ([string] $entry.description).Replace('\', '/')
            if ($description.StartsWith('Input: ', [StringComparison]::OrdinalIgnoreCase) -and
                ($description.Contains($settingsPath, [StringComparison]::OrdinalIgnoreCase) -or
                 $description.Contains($membersPath, [StringComparison]::OrdinalIgnoreCase) -or
                 $description.Contains($markersPath, [StringComparison]::OrdinalIgnoreCase))) {
                throw "The target-time workload was predicted into the weak fingerprint for $($project.name): $description"
            }
        }
        $markerPath = $workload.markerPath.Replace('{projectName}', $project.name).Replace('\', '/')
        $probePrefix = if (Test-Path -LiteralPath (Join-Path $repoRoot $markerPath)) { 'ExistingProbe: ' } else { 'AbsentPathProbe: ' }
        $hasSettingsRead = $false
        $hasEnumeration = $false
        $hasMarkerProbe = $false
        $memberEntries = 0
        foreach ($entry in $dump.strong.entries) {
            $description = ([string] $entry.description).Replace('\', '/')
            if ($description.StartsWith('FileContentRead: ', [StringComparison]::OrdinalIgnoreCase) -and
                $description.EndsWith($settingsPath, [StringComparison]::OrdinalIgnoreCase)) {
                $hasSettingsRead = $true
            }
            if ($description.StartsWith('DirectoryEnumeration: ', [StringComparison]::OrdinalIgnoreCase) -and
                $description.Contains($membersPath, [StringComparison]::OrdinalIgnoreCase)) {
                $hasEnumeration = $true
                if ($description.Contains(' - ', [StringComparison]::Ordinal)) { $memberEntries++ }
            }
            if ($description.StartsWith($probePrefix, [StringComparison]::OrdinalIgnoreCase) -and
                $description.EndsWith($markerPath, [StringComparison]::OrdinalIgnoreCase)) {
                $hasMarkerProbe = $true
            }
        }
        if (-not $hasSettingsRead -or -not $hasEnumeration -or -not $hasMarkerProbe -or $memberEntries -lt $memberCount) {
            throw "Incomplete observed strong fingerprint for $($project.name): settingsRead=$hasSettingsRead, directoryEnumeration=$hasEnumeration, markerProbe=$hasMarkerProbe, directoryMemberEntries=$memberEntries (expected at least $memberCount). Inspect $($dumpFile.FullName)."
        }
        $null = $validated.Add($project.name)
    }
    if ($validated.Count -ne 500) {
        throw "Expected 500 validated observed strong fingerprints; found $($validated.Count). Inspect $PluginLogDirectory."
    }
    return $validated.Count
}

if (-not $IsWindows -and $cacheEnabled) {
    throw 'The published MSBuildCache Local plugin cannot run enabled on Linux: its RocksDB payload is Windows native, and Linux dotnet msbuild does not support the required -reportfileaccesses switch. Use -CacheMode Disabled for the Linux build and workload checks; enabled cache tests require Windows x64 Visual Studio MSBuild.'
}
if (-not $IsWindows -and -not [string]::IsNullOrWhiteSpace($MSBuildPath)) {
    throw 'MSBuildPath applies to Windows Visual Studio MSBuild.exe. Linux disabled builds use dotnet msbuild with the pinned SDK.'
}
if (-not $cacheEnabled -and ($ExpectedHits -ge 0 -or $ExpectedMisses -ge 0)) {
    throw 'ExpectedHits and ExpectedMisses apply only when CacheMode is Enabled.'
}
if ($ValidateFingerprints -and -not $cacheEnabled) {
    throw 'ValidateFingerprints requires CacheMode Enabled so the plugin produces fingerprint dumps.'
}
if ($MeasureMemory -and -not $IsWindows) {
    throw 'MeasureMemory uses the Windows process-tree sampler and requires Windows.'
}

Push-Location -LiteralPath $repoRoot
try {
    & (Join-Path $repoRoot 'scripts/generate.ps1') -VerifyOnly
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'workload.json') -Raw | ConvertFrom-Json -Depth 64
    if ($manifest.graph.projectCount -ne 500 -or $manifest.graph.projectReferenceCount -ne 4750 -or
        @($manifest.projects).Count -ne 500 -or $manifest.verification.expectedValue -ne 395719275) {
        throw 'Expected the generated 500-project, 4,750-reference workload and verification value 395719275.'
    }

    $sdkVersion = (& dotnet --version | Out-String).Trim()
    Assert-NativeSuccess 'Resolving the pinned .NET SDK'
    if ($sdkVersion -ne '10.0.403') {
        throw "The pinned .NET SDK 10.0.403 is required; resolved $sdkVersion."
    }

    if ($IsWindows -and [string]::IsNullOrWhiteSpace($MSBuildPath)) {
        $vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        if (-not (Test-Path -LiteralPath $vswherePath -PathType Leaf)) {
            throw 'Visual Studio Installer vswhere.exe was not found. Install VS 2026 Build Tools or pass -MSBuildPath to its x64 MSBuild.exe.'
        }
        $candidates = @(& $vswherePath -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild/**/Bin/amd64/MSBuild.exe')
        Assert-NativeSuccess 'Finding x64 Visual Studio MSBuild'
        $MSBuildPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($MSBuildPath)) {
            throw 'No x64 Visual Studio MSBuild.exe was found. Install VS 2026 Build Tools or provide -MSBuildPath.'
        }
    }
    $capabilities = $null
    if ($IsWindows) {
        $MSBuildPath = Get-FullRepositoryPath $MSBuildPath
        if (-not (Test-Path -LiteralPath $MSBuildPath -PathType Leaf) -or
            [System.IO.Path]::GetFileName($MSBuildPath) -ine 'MSBuild.exe' -or
            [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($MSBuildPath)) -ine 'amd64') {
            throw "MSBuildPath must identify Visual Studio's Bin/amd64/MSBuild.exe: $MSBuildPath"
        }
        $capabilities = Get-MSBuildCapabilities $MSBuildPath
        if ($cacheEnabled -and -not $capabilities.fileAccessData) {
            throw 'This MSBuild does not expose the required experimental file-access API.'
        }
    }
    else {
        $MSBuildPath = (Get-Command dotnet -ErrorAction Stop).Source
        $msbuildPrefixArguments = @('msbuild')
    }
    $msbuildVersion = (& $MSBuildPath @msbuildPrefixArguments -version -nologo | Out-String).Trim()
    Assert-NativeSuccess 'Checking MSBuild'
    $strongWorkloadProperty = $manifest.PSObject.Properties['strongFingerprintWorkload']
    if ($cacheEnabled -and $null -ne $strongWorkloadProperty -and $strongWorkloadProperty.Value.enabled -and -not $capabilities.enumerationPattern) {
        throw 'The strong-fingerprint workload requires an MSBuild that reports FileAccessData.EnumeratePattern.'
    }

    $gitRoot = $null
    if ($cacheEnabled) {
        Get-Command git -ErrorAction Stop | Out-Null
        $gitRoot = (& git rev-parse --show-toplevel | Out-String).Trim()
        Assert-NativeSuccess 'Finding the Git repository required by MSBuildCache'
        if (-not [string]::Equals((Get-FullRepositoryPath $gitRoot), $repoRoot, $pathComparison)) {
            throw "MSBuildCache requires this workload's own Git repository at $repoRoot; found $gitRoot."
        }
    }

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $runName = '{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $LogDirectory = Join-Path $repoRoot "artifacts/logs/native/$runName"
    }
    if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
        $CacheDirectory = Join-Path $repoRoot 'LocalMSBuildCache'
    }
    $LogDirectory = Get-FullRepositoryPath $LogDirectory
    $CacheDirectory = Get-FullRepositoryPath $CacheDirectory
    if ($LogDirectory.Contains(';')) {
        throw 'LogDirectory cannot contain a semicolon because MSBuild uses it to delimit binary-logger options.'
    }
    $cleanPaths = @(
        (Join-Path $repoRoot 'artifacts/bin'),
        (Join-Path $repoRoot 'artifacts/obj'),
        (Join-Path $repoRoot 'obj')
    )
    foreach ($cleanPath in $cleanPaths) {
        if ((Test-PathsOverlap $CacheDirectory $cleanPath) -or (Test-PathsOverlap $LogDirectory $cleanPath)) {
            throw "CacheDirectory and LogDirectory must remain separate from the build outputs cleaned before each run: $cleanPath"
        }
    }
    foreach ($fileName in @('build.log', 'build.binlog', 'build-summary.json', 'run-metadata.json', 'plugin-state.json', 'verification.log', 'memory.csv', 'memory-summary.json')) {
        if (Test-Path -LiteralPath (Join-Path $LogDirectory $fileName)) {
            throw "LogDirectory already contains a previous run ($fileName). Choose a new directory to preserve its logs."
        }
    }
    $null = New-Item -ItemType Directory -Path $LogDirectory -Force
    $summaryPath = Join-Path $LogDirectory 'build-summary.json'
    if ($cacheEnabled) {
        $null = New-Item -ItemType Directory -Path $CacheDirectory -Force
    }

    & (Join-Path $repoRoot 'scripts/prepare-workload.ps1')

    $metadata = [ordered]@{
        schemaVersion = 1
        startedUtc = [DateTime]::UtcNow.ToString('o')
        repositoryRoot = $repoRoot
        gitRoot = $gitRoot
        sdkVersion = $sdkVersion
        msbuildPath = $MSBuildPath
        msbuildVersion = $msbuildVersion
        msbuildRuntime = $expectedRuntime
        fileAccessCapabilities = $capabilities
        configuration = $Configuration
        maxCpuCount = $MaxCpuCount
        cacheMode = $CacheMode
        cacheDirectory = $CacheDirectory
        cacheUniverse = $CacheUniverse
        cachePackageVersion = $cachePackageVersion
        cacheImplementation = $cacheImplementation
        localPackageBuild = $localPackages
        expectedHits = $ExpectedHits
        expectedMisses = $ExpectedMisses
        measureMemory = $MeasureMemory.IsPresent
        sampleIntervalSeconds = $(if ($MeasureMemory) { $SampleSeconds } else { $null })
        validateFingerprints = $ValidateFingerprints.IsPresent
        freshOutputDirectories = $cleanPaths
    }
    $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $LogDirectory 'run-metadata.json') -Encoding utf8NoBOM
    Remove-FreshBuildOutputs $cleanPaths

    Write-Host "Building 500 projects / 4,750 project references with fresh outputs."
    Write-Host "SDK: $sdkVersion | MSBuild: $msbuildVersion | Workers: $MaxCpuCount | Cache: $CacheMode"
    Write-Host "Implementation: $cacheImplementation | Package version: $cachePackageVersion"
    Write-Host "MSBuild: $MSBuildPath"
    Write-Host "Cache directory: $CacheDirectory | Universe: $CacheUniverse"
    Write-Host "Logs: $LogDirectory"

    $pluginLogDirectory = Join-Path $LogDirectory 'MSBuildCacheLogs'
    $settingsArguments = @(
        "-property:Configuration=$Configuration",
        "-property:MSBuildCacheEnabled=$cacheEnabledText",
        '-property:MSBuildCacheAsyncCacheMaterialization=false',
        "-property:MSBuildCacheLocalCacheRootPath=$(ConvertTo-MSBuildPropertyValue $CacheDirectory)",
        "-property:MSBuildCacheCacheUniverse=$(ConvertTo-MSBuildPropertyValue $CacheUniverse)",
        "-property:MSBuildCacheLogDirectory=$(ConvertTo-MSBuildPropertyValue $pluginLogDirectory)"
    )
    if ($null -ne $localPackages) {
        $restoreConfig = Join-Path (Split-Path -Parent $LocalPackageManifest) 'NuGet.config'
        if (-not (Test-Path -LiteralPath $restoreConfig -PathType Leaf)) { throw "Missing local restore configuration: $restoreConfig" }
        $settingsArguments += @(
            "-property:MSBuildCachePackageVersion=$cachePackageVersion",
            "-property:RestoreConfigFile=$(ConvertTo-MSBuildPropertyValue $restoreConfig)"
        )
    }
    $arguments = @(
        'dirs.proj',
        '-restore',
        '-graphBuild',
        "-maxCpuCount:$MaxCpuCount",
        '-nodeReuse:false',
        "-binaryLogger:$(Join-Path $LogDirectory 'build.binlog');ProjectImports=None",
        '-verbosity:minimal',
        '-nologo'
    ) + $settingsArguments
    if ($cacheEnabled) {
        $arguments += '-reportfileaccesses'
    }
    $restoreBuildTimer = [Diagnostics.Stopwatch]::StartNew()
    if ($MeasureMemory) {
        $measurementParameters = @{
            Executable = $MSBuildPath
            ExecutableArguments = @($msbuildPrefixArguments) + @($arguments)
            WorkingDirectory = $repoRoot
            ResultsDirectory = $LogDirectory
            LogFile = Join-Path $LogDirectory 'build.log'
            Configuration = $Configuration
            MaxCpuCount = $MaxCpuCount
            CacheMode = $CacheMode
            CacheUniverse = $CacheUniverse
            SampleSeconds = $SampleSeconds
        }
        & (Join-Path $repoRoot 'scripts/measure-process.ps1') @measurementParameters
        Assert-NativeSuccess 'Traversal restore/build'
        $memorySummary = Get-Content -LiteralPath (Join-Path $LogDirectory 'memory-summary.json') -Raw | ConvertFrom-Json
        $restoreBuildSeconds = [double] $memorySummary.processElapsedSeconds
        if ($memorySummary.exitCode -ne 0 -or $memorySummary.samplingFailed -or
            [double]::IsNaN($restoreBuildSeconds) -or [double]::IsInfinity($restoreBuildSeconds) -or $restoreBuildSeconds -lt 0) {
            throw 'The MSBuild memory sampler did not produce a successful process-duration report.'
        }
    }
    else {
        & $MSBuildPath @msbuildPrefixArguments @arguments 2>&1 | Tee-Object -FilePath (Join-Path $LogDirectory 'build.log')
        Assert-NativeSuccess 'Traversal restore/build'
        $restoreBuildSeconds = $restoreBuildTimer.Elapsed.TotalSeconds
    }
    $restoreBuildTimer.Stop()
    Write-Host ("MSBuild restore/build completed in {0:N3} seconds." -f $restoreBuildSeconds)

    $buildText = Get-Content -LiteralPath (Join-Path $LogDirectory 'build.log') -Raw
    $hitMatches = [regex]::Matches($buildText, 'Cache Hit Count:\s*(?<Value>\d+)')
    $missMatches = [regex]::Matches($buildText, 'Cache Miss Count:\s*(?<Value>\d+)')
    $hits = $null
    $misses = $null
    if ($cacheEnabled) {
        if ($hitMatches.Count -ne 1 -or $missMatches.Count -ne 1) {
            throw 'Expected exactly one actual MSBuildCache hit/miss summary. The plugin may have disabled itself; inspect build.log.'
        }
        $hits = [int] $hitMatches[0].Groups['Value'].Value
        $misses = [int] $missMatches[0].Groups['Value'].Value
        if (($hits + $misses) -ne 500) {
            throw "Expected 500 actual project-cache queries; observed $hits hits and $misses misses."
        }
        if (($ExpectedHits -ge 0 -and $hits -ne $ExpectedHits) -or ($ExpectedMisses -ge 0 -and $misses -ne $ExpectedMisses)) {
            throw "Cache statistics differ: observed hits=$hits, misses=$misses; expected hits=$ExpectedHits, misses=$ExpectedMisses (-1 means unchecked)."
        }
    }
    elseif ($hitMatches.Count -ne 0 -or $missMatches.Count -ne 0) {
        throw 'The disabled control unexpectedly produced MSBuildCache statistics.'
    }

    $evaluationArguments = @(
        $manifest.projects[0].path,
        '-getProperty:MSBuildCacheEnabled,MSBuildRuntimeType,MSBuildCacheAssembly,MSBuildCacheSharedCompilationAssembly,NETCoreSdkVersion',
        '-getItem:ProjectCachePlugin,PackageReference,PackageVersion',
        '-nologo'
    ) + $settingsArguments
    $evaluationText = (& $MSBuildPath @msbuildPrefixArguments @evaluationArguments | Out-String)
    Assert-NativeSuccess 'Checking the evaluated plugin configuration'
    $evaluationText | Set-Content -LiteralPath (Join-Path $LogDirectory 'plugin-state.json') -Encoding utf8NoBOM
    $evaluation = $evaluationText | ConvertFrom-Json -Depth 64
    $plugins = @($evaluation.Items.ProjectCachePlugin)
    $expectedPluginCount = if ($cacheEnabled) { 1 } else { 0 }
    if ($evaluation.Properties.MSBuildCacheEnabled -ne $cacheEnabledText -or $plugins.Count -ne $expectedPluginCount -or
        $evaluation.Properties.MSBuildRuntimeType -ne $expectedRuntime -or $evaluation.Properties.NETCoreSdkVersion -ne '10.0.403') {
        throw 'The evaluated MSBuild runtime, SDK, cache setting, or registered plugin count differs from the requested configuration.'
    }
    $pluginReferences = @($evaluation.Items.PackageReference | Where-Object Identity -eq 'Microsoft.MSBuildCache.Local')
    $pluginVersions = @($evaluation.Items.PackageVersion | Where-Object Identity -eq 'Microsoft.MSBuildCache.Local')
    if ($pluginReferences.Count -ne 1 -or $pluginVersions.Count -ne 1 -or $pluginVersions[0].Version -ne $cachePackageVersion) {
        throw "Expected Microsoft.MSBuildCache.Local $cachePackageVersion ($cacheImplementation)."
    }
    $helperReferences = @($evaluation.Items.PackageReference | Where-Object Identity -eq 'Microsoft.MSBuildCache.SharedCompilation')
    $helperVersions = @($evaluation.Items.PackageVersion | Where-Object Identity -eq 'Microsoft.MSBuildCache.SharedCompilation')
    if ($helperReferences.Count -ne $expectedPluginCount -or $helperVersions.Count -ne 1 -or $helperVersions[0].Version -ne $cachePackageVersion) {
        throw "Expected SharedCompilation $cachePackageVersion to be referenced exactly when caching is enabled."
    }
    $pluginAssemblyHash = $null
    $helperAssemblyHash = $null
    if ($cacheEnabled) {
        if (-not (Test-Path -LiteralPath $plugins[0].Identity -PathType Leaf) -or
            -not (Test-Path -LiteralPath $evaluation.Properties.MSBuildCacheSharedCompilationAssembly -PathType Leaf)) {
            throw 'The actual Local plugin or SharedCompilation helper assembly is missing.'
        }
        $pluginAssemblyHash = (Get-FileHash -LiteralPath $plugins[0].Identity -Algorithm SHA256).Hash
        $helperAssemblyHash = (Get-FileHash -LiteralPath $evaluation.Properties.MSBuildCacheSharedCompilationAssembly -Algorithm SHA256).Hash
        if ($null -ne $localPackages -and
            ($pluginAssemblyHash -ne $localPackages.localPluginAssemblySha256 -or
             $helperAssemblyHash -ne $localPackages.sharedCompilationAssemblySha256)) {
            throw 'The loaded plugin/helper does not match the freshly built local packages.'
        }
    }

    $missing = @(
        foreach ($project in $manifest.projects) {
            $assemblyPath = Join-Path $repoRoot ($project.assemblyPath.Replace('{configuration}', $Configuration))
            if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
                $assemblyPath
            }
        }
    )
    if ($missing.Count -gt 0) {
        throw "The build did not produce all 500 primary assemblies. Missing: $($missing -join ', ')"
    }
    $workloadSidecarsVerified = Assert-WorkloadSidecars $manifest
    $observedStrongFingerprintCount = 0
    if ($ValidateFingerprints) {
        Write-Host 'Validating observed strong fingerprints after the measured MSBuild process has exited.'
        $observedStrongFingerprintCount = Assert-ObservedStrongFingerprints $manifest $pluginLogDirectory
    }
    $observedStrongFingerprintsValidated = $observedStrongFingerprintCount -eq 500
    $verificationAssembly = Join-Path $repoRoot ($manifest.verification.assemblyPath.Replace('{configuration}', $Configuration))
    & dotnet $verificationAssembly 2>&1 | Tee-Object -FilePath (Join-Path $LogDirectory 'verification.log')
    Assert-NativeSuccess 'Running the workload verification application'
    $timer.Stop()

    $summary = [ordered]@{
        schemaVersion = 1
        sdkVersion = $sdkVersion
        msbuildPath = $MSBuildPath
        msbuildVersion = $msbuildVersion
        msbuildRuntime = $expectedRuntime
        configuration = $Configuration
        projectCount = 500
        projectReferenceCount = 4750
        implicitTransitiveProjectReferences = $false
        verifiedPrimaryAssemblies = 500
        msbuildCacheEnabled = $cacheEnabled
        msbuildCachePackageVersion = $cachePackageVersion
        cacheImplementation = $cacheImplementation
        pluginAssemblySha256 = $pluginAssemblyHash
        sharedCompilationAssemblySha256 = $helperAssemblyHash
        localSourceSnapshotCommit = $(if ($null -ne $localPackages) { $localPackages.sourceSnapshotCommit } else { $null })
        registeredCachePlugins = $plugins.Count
        workloadSidecarsVerified = $workloadSidecarsVerified
        pluginObservedWorkload = $observedStrongFingerprintsValidated
        observedStrongFingerprintsValidated = $observedStrongFingerprintsValidated
        observedStrongFingerprintCount = $observedStrongFingerprintCount
        fingerprintValidationRequested = $ValidateFingerprints.IsPresent
        memoryMeasured = $MeasureMemory.IsPresent
        cacheDirectory = $CacheDirectory
        cacheUniverse = $CacheUniverse
        cacheHits = $hits
        cacheMisses = $misses
        verificationExpectedValue = $manifest.verification.expectedValue
        restoreBuildSeconds = [Math]::Round($restoreBuildSeconds, 3)
        elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        succeeded = $true
    }
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM
    Write-Host "PASS: all 500 assemblies and target-time input sidecars verified; Project0499 verified 395719275. Cache: $CacheMode; hits=$hits; misses=$misses."
    if (-not $cacheEnabled) {
        Write-Host 'Caching is disabled: the sidecars verify target execution and input state, not plugin observations or computed strong fingerprints.'
    }
    elseif (-not $ValidateFingerprints) {
        Write-Host 'Fingerprint dump validation was not requested; observed strong fingerprints were not validated.'
    }
    Write-Host ("Total elapsed, including verification: {0:N1} seconds" -f $timer.Elapsed.TotalSeconds)
}
catch {
    $timer.Stop()
    if ($null -ne $summaryPath) {
        [ordered]@{
            schemaVersion = 1
            cacheMode = $CacheMode
            elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
            succeeded = $false
            error = $_.Exception.Message
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM
    }
    throw
}
finally {
    Pop-Location
}
