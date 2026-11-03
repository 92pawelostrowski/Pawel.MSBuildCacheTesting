#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidateRange(1, 256)]
    [int] $MaxCpuCount = 2,

    [ValidateRange(1, 3600)]
    [int] $SampleSeconds = 2,

    [string] $ResultsDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$imageName = 'pawel-msbuildcachetesting:local'

Get-Command docker -ErrorAction Stop | Out-Null
$dockerOs = & docker info --format '{{.OSType}}'
if ($LASTEXITCODE -ne 0) { throw 'Docker is not running or is not accessible.' }
if ($dockerOs.Trim() -ne 'linux') { throw 'This build requires Docker configured for Linux containers.' }

if (-not $ResultsDirectory) {
    $runName = '{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $ResultsDirectory = Join-Path $repositoryRoot "artifacts/docker/$runName"
}
elseif (-not [IO.Path]::IsPathRooted($ResultsDirectory)) {
    $ResultsDirectory = Join-Path $repositoryRoot $ResultsDirectory
}
$ResultsDirectory = [IO.Path]::GetFullPath($ResultsDirectory)
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null

Write-Host "Building Linux SDK image from $repositoryRoot"
& docker build --file (Join-Path $repositoryRoot 'Dockerfile') --tag $imageName $repositoryRoot
if ($LASTEXITCODE -ne 0) { throw "Docker image build failed (exit $LASTEXITCODE)." }

$runArguments = @(
    'run', '--rm',
    '--mount', "type=bind,source=$ResultsDirectory,target=/results",
    '--env', "CONFIGURATION=$Configuration",
    '--env', "MAX_CPU_COUNT=$MaxCpuCount",
    '--env', "MEMORY_SAMPLE_SECONDS=$SampleSeconds"
)
if ($IsLinux -or $IsMacOS) {
    $buildUid = & id -u
    if ($LASTEXITCODE -ne 0) { throw 'Could not determine the current user ID.' }
    $buildGid = & id -g
    if ($LASTEXITCODE -ne 0) { throw 'Could not determine the current group ID.' }
    $runArguments += @('--user', "${buildUid}:${buildGid}")
}
$runArguments += $imageName

Write-Host "Running a fresh traversal build; memory sampling is always enabled."
Write-Host "Results: $ResultsDirectory"
& docker @runArguments 2>&1 | Tee-Object -FilePath (Join-Path $ResultsDirectory 'console.log')
$buildExitCode = $LASTEXITCODE
if ($buildExitCode -ne 0) { throw "Container build failed (exit $buildExitCode). Results: $ResultsDirectory" }
Write-Host "Docker build and verification succeeded. Results: $ResultsDirectory"
