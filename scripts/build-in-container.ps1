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
    [ValidateNotNullOrEmpty()]
    [string] $CacheUniverse = 'published-0.1.340-preview-v1',
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
}
& (Join-Path $PSScriptRoot '..\build.ps1') @buildParameters
