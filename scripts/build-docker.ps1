#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Published')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [ValidateNotNullOrEmpty()]
    [string] $MSBuildCachePackageDirectory,
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [ValidateRange(1, 256)]
    [int] $MaxCpuCount = 2,
    [ValidateRange(1, 3600)]
    [int] $SampleSeconds = 2,
    [string] $ResultsDirectory,
    [string] $CacheDirectory,
    [ValidateNotNullOrEmpty()]
    [string] $DockerContext = 'windows-containers',
    [string] $CacheUniverse = '',
    [Parameter(ParameterSetName = 'Published')]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $CacheMode = 'Enabled',
    [ValidateRange(-1, 500)]
    [int] $ExpectedHits = -1,
    [ValidateRange(-1, 500)]
    [int] $ExpectedMisses = -1,
    [switch] $ValidateFingerprints
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This launcher requires Windows and a local Windows container engine.'
}
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$usingLocalPackages = $PSCmdlet.ParameterSetName -eq 'Local'
if ($CacheMode -eq 'Disabled' -and ($ValidateFingerprints -or $ExpectedHits -ge 0 -or $ExpectedMisses -ge 0)) {
    throw 'Disabled mode cannot validate plugin fingerprints or cache hit/miss counts.'
}
if ($usingLocalPackages) {
    if (-not [IO.Path]::IsPathRooted($MSBuildCachePackageDirectory)) {
        $MSBuildCachePackageDirectory = Join-Path $repositoryRoot $MSBuildCachePackageDirectory
    }
    $MSBuildCachePackageDirectory = [IO.Path]::GetFullPath($MSBuildCachePackageDirectory)
    if ($MSBuildCachePackageDirectory -notmatch '^[A-Za-z]:[\\/]' -or $MSBuildCachePackageDirectory.Contains(',')) {
        throw 'MSBuildCachePackageDirectory must be an absolute local Windows drive path without commas.'
    }
    if (-not (Test-Path -LiteralPath $MSBuildCachePackageDirectory -PathType Container)) {
        throw "MSBuildCachePackageDirectory does not exist: $MSBuildCachePackageDirectory"
    }
    foreach ($id in @('Microsoft.MSBuildCache.Local', 'Microsoft.MSBuildCache.SharedCompilation')) {
        $packages = @(Get-ChildItem -LiteralPath $MSBuildCachePackageDirectory -Filter "$id.*.nupkg" -File)
        if ($packages.Count -ne 1) {
            throw "Expected exactly one $id package in $MSBuildCachePackageDirectory. Use a directory containing one version of each package."
        }
    }
}
elseif ([string]::IsNullOrWhiteSpace($CacheUniverse)) {
    $CacheUniverse = 'published-0.1.340-preview-v1'
}
Get-Command docker -ErrorAction Stop | Out-Null
if (-not $PSBoundParameters.ContainsKey('DockerContext')) {
    $contextNames = @(& docker context ls --format '{{.Name}}')
    if ($LASTEXITCODE -ne 0) { throw 'Could not list Docker contexts.' }
    if ($contextNames -notcontains $DockerContext) {
        $DockerContext = (& docker context show | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($DockerContext)) {
            throw 'Could not determine the current Docker context. Supply -DockerContext explicitly.'
        }
    }
}
$dockerPrefix = @('--context', $DockerContext)
$dockerEndpoint = (& docker context inspect $DockerContext --format '{{.Endpoints.docker.Host}}' | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Could not inspect Docker context '$DockerContext'." }
if (-not $dockerEndpoint.StartsWith('npipe://', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Docker context '$DockerContext' must use a local Windows named pipe; remote engines are not supported."
}
$dockerOs = (& docker @dockerPrefix info --format '{{.OSType}}' | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Docker context '$DockerContext' is not running or is not accessible." }
if ($dockerOs -ne 'windows') {
    throw "Windows containers are required; context '$DockerContext' currently serves '$dockerOs'. This script does not switch engines or change host settings."
}
Write-Host "Docker context: $DockerContext (local Windows engine)"

$imageName = 'pawel-msbuildcachetesting:windows-local'
if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    $runName = '{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $ResultsDirectory = Join-Path $repositoryRoot "artifacts/docker/$runName"
}
elseif (-not [IO.Path]::IsPathRooted($ResultsDirectory)) {
    $ResultsDirectory = Join-Path $repositoryRoot $ResultsDirectory
}
if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
    $cacheFolder = if ($usingLocalPackages) { 'LocalMSBuildCache\Local' } else { 'LocalMSBuildCache' }
    $CacheDirectory = Join-Path $repositoryRoot $cacheFolder
}
elseif (-not [IO.Path]::IsPathRooted($CacheDirectory)) {
    $CacheDirectory = Join-Path $repositoryRoot $CacheDirectory
}
$ResultsDirectory = [IO.Path]::GetFullPath($ResultsDirectory)
$CacheDirectory = [IO.Path]::GetFullPath($CacheDirectory)
foreach ($previousResult in @('console.log', 'build-summary.json', 'local-packages\manifest.json')) {
    if (Test-Path -LiteralPath (Join-Path $ResultsDirectory $previousResult)) {
        throw "ResultsDirectory already contains a previous run ($previousResult). Choose a new directory."
    }
}
foreach ($mountPath in @($CacheDirectory, $ResultsDirectory)) {
    if ($mountPath -notmatch '^[A-Za-z]:[\\/]' -or $mountPath.Contains(',')) {
        throw "Docker bind sources must be absolute Windows drive paths without commas: $mountPath"
    }
}
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null

$containerName = 'msbuildcache-test-' + [Guid]::NewGuid().ToString('N')
$runArguments = @(
    'run', '--name', $containerName, '--isolation', 'process',
    '--mount', "type=bind,source=$ResultsDirectory,target=C:\results",
    '--mount', "type=bind,source=$CacheDirectory,target=C:\MSBuildCache"
)
if ($usingLocalPackages) {
    $runArguments += @('--mount', "type=bind,source=$MSBuildCachePackageDirectory,target=C:\packages,readonly")
}
$runArguments += @(
    $imageName,
    '-Configuration', $Configuration,
    '-MaxCpuCount', [string]$MaxCpuCount,
    '-SampleSeconds', [string]$SampleSeconds,
    '-ResultsDirectory', 'C:\results',
    '-CacheDirectory', 'C:\MSBuildCache',
    '-CacheMode', $CacheMode,
    '-ExpectedHits', [string]$ExpectedHits,
    '-ExpectedMisses', [string]$ExpectedMisses
)
if (-not [string]::IsNullOrWhiteSpace($CacheUniverse)) { $runArguments += @('-CacheUniverse', $CacheUniverse) }
if ($usingLocalPackages) { $runArguments += @('-MSBuildCachePackageDirectory', 'C:\packages') }
if ($ValidateFingerprints) { $runArguments += '-ValidateFingerprints' }

# Request system wakefulness only while building and running. This does not
# change the power plan or prevent the display from turning off.
if (-not ('MSBuildCacheExecutionState' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class MSBuildCacheExecutionState
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@
}
$previousExecutionState = [MSBuildCacheExecutionState]::SetThreadExecutionState(2147483649)
if ($previousExecutionState -eq 0) { throw 'Could not request that Windows stay awake during the build.' }
$buildExitCode = 1
try {
    Write-Host "Building Windows Server Core / Visual Studio MSBuild image from $repositoryRoot"
    & docker @dockerPrefix build --isolation process --memory 4g --file (Join-Path $repositoryRoot 'Dockerfile') --tag $imageName $repositoryRoot
    if ($LASTEXITCODE -ne 0) { throw "Docker image build failed (exit $LASTEXITCODE)." }

    Write-Host 'Running a fresh Windows traversal build; MSBuild memory sampling is always enabled.'
    Write-Host "Cache mode: $CacheMode | Cache universe: $CacheUniverse"
    if ($usingLocalPackages) {
        Write-Host "Local packages: $MSBuildCachePackageDirectory (read-only)"
        if ([string]::IsNullOrWhiteSpace($CacheUniverse)) { Write-Host 'Cache universe will be derived from the supplied package hashes.' }
    }
    Write-Host "Persistent host cache: $CacheDirectory"
    Write-Host "Results: $ResultsDirectory"
    try {
        # Windows PowerShell represents redirected native stderr as error records,
        # even when the executable succeeds. Preserve its text and check the exit code.
        $ErrorActionPreference = 'Continue'
        & docker @dockerPrefix @runArguments 2>&1 |
            ForEach-Object { $_.ToString() } |
            Tee-Object -FilePath (Join-Path $ResultsDirectory 'console.log') -ErrorAction Stop
        $buildExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = 'Stop'
        # Remove only this invocation's uniquely named container; bind mounts survive.
        & { $ErrorActionPreference = 'Continue'; & docker @dockerPrefix rm --force $containerName 2>&1 | Out-Null }
    }
}
finally {
    $null = [MSBuildCacheExecutionState]::SetThreadExecutionState($previousExecutionState)
}
if ($buildExitCode -ne 0) { throw "Container build failed (exit $buildExitCode). Results: $ResultsDirectory" }
Write-Host "Windows Docker build and verification succeeded. Results: $ResultsDirectory"
