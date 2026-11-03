#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [ValidateRange(1, 256)]
    [int] $MaxCpuCount = 2,
    [ValidateRange(1, 3600)]
    [int] $SampleSeconds = 2,
    [string] $ResultsDirectory = 'C:\results',
    [string] $CacheDirectory = 'C:\MSBuildCache',
    [string] $CacheUniverse = '',
    [string] $MSBuildCachePackageDirectory,
    [ValidateSet('Enabled', 'Disabled')]
    [string] $CacheMode = 'Enabled',
    [switch] $ValidateFingerprints,
    [ValidateRange(-1, 500)]
    [int] $ExpectedHits = -1,
    [ValidateRange(-1, 500)]
    [int] $ExpectedMisses = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This container entrypoint requires Windows.' }

# Snapshot and validate supplied packages before measuring the workload.
$localPackageManifest = ''
if ($MSBuildCachePackageDirectory) {
    if ($CacheMode -ne 'Enabled') { throw 'Local packages require caching to be enabled.' }
    $packageDirectory = Join-Path $ResultsDirectory 'local-packages'
    $localPackageManifest = & (Join-Path $PSScriptRoot 'prepare-local-packages.ps1') -PackageDirectory $MSBuildCachePackageDirectory -OutputDirectory $packageDirectory
    $localPackages = Get-Content -LiteralPath $localPackageManifest -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($CacheUniverse)) { $CacheUniverse = $localPackages.cacheUniverse }
}
elseif ([string]::IsNullOrWhiteSpace($CacheUniverse)) {
    $CacheUniverse = 'published-0.1.340-preview-v1'
}

# build.ps1 measures only its actual MSBuild invocation. Preparation and output
# verification run outside the measured process tree.
$buildParameters = @{
    Configuration = $Configuration
    MaxCpuCount = $MaxCpuCount
    LogDirectory = $ResultsDirectory
    CacheDirectory = $CacheDirectory
    CacheUniverse = $CacheUniverse
    CacheMode = $CacheMode
    MSBuildPath = 'C:\BuildTools\MSBuild\Current\Bin\amd64\MSBuild.exe'
    ExpectedHits = $ExpectedHits
    ExpectedMisses = $ExpectedMisses
    MeasureMemory = $true
    SampleSeconds = $SampleSeconds
    ValidateFingerprints = $ValidateFingerprints
    LocalPackageManifest = $localPackageManifest
}
& (Join-Path $PSScriptRoot '..\build.ps1') @buildParameters
