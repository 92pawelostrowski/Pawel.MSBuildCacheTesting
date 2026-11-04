#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Docker', 'Native')]
    [string] $Backend = 'Docker',

    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidateRange(1, 256)]
    [int] $MaxCpuCount = 2,

    [string] $CacheDirectory = '',
    [string] $ResultsDirectory = '',
    [string] $CacheUniverse = '',
    [string] $MSBuildPath = '',
    [string] $DockerContext = 'windows-containers'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'This test harness supports Windows only.' }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
if ([string]::IsNullOrWhiteSpace($CacheDirectory)) { $CacheDirectory = Join-Path $repoRoot 'LocalMSBuildCache' }
if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) { $ResultsDirectory = Join-Path $repoRoot "artifacts/tests/$runId" }
if ([string]::IsNullOrWhiteSpace($CacheUniverse)) { $CacheUniverse = "published-0.1.340-preview-$runId" }
if (-not [IO.Path]::IsPathRooted($CacheDirectory)) { $CacheDirectory = Join-Path $repoRoot $CacheDirectory }
if (-not [IO.Path]::IsPathRooted($ResultsDirectory)) { $ResultsDirectory = Join-Path $repoRoot $ResultsDirectory }
$CacheDirectory = [IO.Path]::GetFullPath($CacheDirectory)
$ResultsDirectory = [IO.Path]::GetFullPath($ResultsDirectory)

function Read-PhaseSummary([string] $Directory, [int] $Hits, [int] $Misses) {
    $path = Join-Path $Directory 'build-summary.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The phase did not produce a build summary: $path"
    }
    $summary = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 64
    if ($summary.schemaVersion -ne 1 -or $summary.succeeded -ne $true -or $summary.msbuildCacheEnabled -ne $true -or
        $summary.cacheHits -ne $Hits -or $summary.cacheMisses -ne $Misses -or
        $summary.projectCount -ne 500 -or $summary.projectReferenceCount -ne 4750 -or
        $summary.verifiedPrimaryAssemblies -ne 500 -or $summary.workloadSidecarsVerified -ne 500 -or
        $summary.observedStrongFingerprintsValidated -ne $true -or $summary.observedStrongFingerprintCount -ne 500 -or
        $summary.registeredCachePlugins -ne 1 -or $summary.msbuildRuntime -ne 'Full' -or
        $summary.sdkVersion -ne '10.0.403' -or $summary.msbuildCachePackageVersion -ne '0.1.340-preview' -or
        $summary.cacheUniverse -cne $CacheUniverse -or $summary.configuration -cne $Configuration -or
        $summary.verificationExpectedValue -ne 395719275) {
        throw "The phase did not verify the enabled published plugin, expected counters, all 500 outputs and observed strong fingerprints: $path"
    }
    return $summary
}

function Read-MemorySummary([string] $Directory) {
    $summaryPath = Join-Path $Directory 'memory-summary.json'
    $csvPath = Join-Path $Directory 'memory.csv'
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf) -or -not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
        throw "The container phase did not produce its mandatory memory CSV and JSON: $Directory"
    }
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 32
    $samples = @(Import-Csv -LiteralPath $csvPath)
    if ($summary.schemaVersion -ne 2 -or $summary.exitCode -ne 0 -or $summary.samplingFailed -ne $false -or $summary.sampleIntervalSeconds -ne 2 -or
        $summary.configuration -cne $Configuration -or $summary.cacheUniverse -cne $CacheUniverse -or
        $summary.cacheMode -cne 'Enabled' -or $summary.maxCpuCount -ne $MaxCpuCount -or
        $summary.sampleCount -lt 2 -or $samples.Count -ne $summary.sampleCount -or
        $summary.peakSampledBuildTreePrivateBytes -le 0 -or $summary.peakSampledBuildTreeWorkingSetBytes -le 0) {
        throw "The container phase has incomplete or unsuccessful two-second memory sampling: $summaryPath"
    }
    $privatePeak = 0L
    $workingSetPeak = 0L
    foreach ($sample in $samples) {
        $privateBytes = [long] $sample.build_tree_private_bytes
        $workingSetBytes = [long] $sample.build_tree_working_set_bytes
        if ($privateBytes -lt 0 -or $workingSetBytes -lt 0) {
            throw "The container memory CSV contains a negative sample: $csvPath"
        }
        $privatePeak = [Math]::Max($privatePeak, $privateBytes)
        $workingSetPeak = [Math]::Max($workingSetPeak, $workingSetBytes)
    }
    if ($privatePeak -ne $summary.peakSampledBuildTreePrivateBytes -or
        $workingSetPeak -ne $summary.peakSampledBuildTreeWorkingSetBytes) {
        throw "The container memory CSV and JSON peaks differ: $summaryPath"
    }
    return $summary
}

if ($Backend -eq 'Docker') {
    Get-Command docker -ErrorAction Stop | Out-Null
    $dockerOs = & docker --context $DockerContext info --format '{{.OSType}}'
    if ($LASTEXITCODE -ne 0 -or "$dockerOs".Trim() -ne 'windows') {
        throw "A reachable Windows container engine is required for Docker context '$DockerContext'."
    }
}

$null = New-Item -ItemType Directory -Path $CacheDirectory -Force
$null = New-Item -ItemType Directory -Path $ResultsDirectory -Force
foreach ($path in @(
    (Join-Path $ResultsDirectory 'test-summary.json'),
    (Join-Path $ResultsDirectory 'cold/build-summary.json'),
    (Join-Path $ResultsDirectory 'warm/build-summary.json'),
    (Join-Path $ResultsDirectory 'replay/build-summary.json')
)) {
    if (Test-Path -LiteralPath $path) {
        throw "ResultsDirectory already contains campaign results; choose a fresh directory: $path"
    }
}
$campaignLock = $null
$results = [Collections.Generic.List[object]]::new()
$campaignTimer = [Diagnostics.Stopwatch]::StartNew()
$phaseName = $null
try {
    $campaignLock = [IO.File]::Open((Join-Path $CacheDirectory '.test-campaign.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $phases = @(
        @{ Name = 'cold'; Hits = 0; Misses = 500 },
        @{ Name = 'warm'; Hits = 500; Misses = 0 },
        @{ Name = 'replay'; Hits = 500; Misses = 0 }
    )
    Write-Host "Cache test: $Backend | Universe: $CacheUniverse"
    Write-Host "Persistent cache: $CacheDirectory"
    Write-Host 'Each phase starts with fresh build outputs; the cache is preserved.'
    foreach ($phase in $phases) {
        $phaseName = $phase.Name
        $phaseDirectory = Join-Path $ResultsDirectory $phase.Name
        $parameters = @{
            Configuration = $Configuration
            MaxCpuCount = $MaxCpuCount
            CacheDirectory = $CacheDirectory
            CacheUniverse = $CacheUniverse
            CacheMode = 'Enabled'
            ExpectedHits = $phase.Hits
            ExpectedMisses = $phase.Misses
            ValidateFingerprints = $true
        }
        Write-Host "Running $($phase.Name): expected $($phase.Hits) hits / $($phase.Misses) misses"
        if ($Backend -eq 'Docker') {
            $parameters.ResultsDirectory = $phaseDirectory
            $parameters.DockerContext = $DockerContext
            $parameters.SampleSeconds = 2
            & (Join-Path $PSScriptRoot 'build-docker.ps1') @parameters
        }
        else {
            $parameters.LogDirectory = $phaseDirectory
            if (-not [string]::IsNullOrWhiteSpace($MSBuildPath)) { $parameters.MSBuildPath = $MSBuildPath }
            & (Join-Path $repoRoot 'build.ps1') @parameters
        }
        $summary = Read-PhaseSummary $phaseDirectory $phase.Hits $phase.Misses
        $memory = if ($Backend -eq 'Docker') { Read-MemorySummary $phaseDirectory } else { $null }
        $results.Add([ordered]@{
            phase = $phase.Name
            cacheHits = $summary.cacheHits
            cacheMisses = $summary.cacheMisses
            observedStrongFingerprintCount = $summary.observedStrongFingerprintCount
            workloadSidecarsVerified = $summary.workloadSidecarsVerified
            buildSummaryPath = Join-Path $phaseDirectory 'build-summary.json'
            memoryCsvPath = $(if ($null -ne $memory) { Join-Path $phaseDirectory 'memory.csv' } else { $null })
            memorySummaryPath = $(if ($null -ne $memory) { Join-Path $phaseDirectory 'memory-summary.json' } else { $null })
            memorySampleCount = $(if ($null -ne $memory) { $memory.sampleCount } else { $null })
            peakSampledBuildTreePrivateBytes = $(if ($null -ne $memory) { $memory.peakSampledBuildTreePrivateBytes } else { $null })
            peakSampledBuildTreeWorkingSetBytes = $(if ($null -ne $memory) { $memory.peakSampledBuildTreeWorkingSetBytes } else { $null })
        })
    }
    $campaignTimer.Stop()
    [ordered]@{
        schemaVersion = 1
        backend = $Backend
        cacheDirectory = $CacheDirectory
        cacheUniverse = $CacheUniverse
        configuration = $Configuration
        maxCpuCount = $MaxCpuCount
        dockerContext = $(if ($Backend -eq 'Docker') { $DockerContext } else { $null })
        memorySampleIntervalSeconds = $(if ($Backend -eq 'Docker') { 2 } else { $null })
        elapsedSeconds = [Math]::Round($campaignTimer.Elapsed.TotalSeconds, 3)
        phases = @($results.ToArray())
        succeeded = $true
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'test-summary.json') -Encoding utf8NoBOM
    Write-Host "PASS: cold miss, warm hit, and repeated replay. Results: $ResultsDirectory"
}
catch {
    $campaignTimer.Stop()
    [ordered]@{
        schemaVersion = 1
        backend = $Backend
        cacheDirectory = $CacheDirectory
        cacheUniverse = $CacheUniverse
        failedPhase = $phaseName
        phases = @($results.ToArray())
        elapsedSeconds = [Math]::Round($campaignTimer.Elapsed.TotalSeconds, 3)
        succeeded = $false
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'test-summary.json') -Encoding utf8NoBOM
    throw
}
finally {
    if ($null -ne $campaignLock) { $campaignLock.Dispose() }
}
