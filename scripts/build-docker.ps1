#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Published')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [ValidateNotNullOrEmpty()]
    [string] $MSBuildCacheRepository,
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
    [ValidateNotNullOrEmpty()]
    [string] $NetworkName = 'pawel-msbuildcachetesting',
    [string[]] $DnsServers,
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
$usingLocalImplementation = $PSCmdlet.ParameterSetName -eq 'Local'
if ($CacheMode -eq 'Disabled' -and ($ValidateFingerprints -or $ExpectedHits -ge 0 -or $ExpectedMisses -ge 0)) {
    throw 'Disabled mode cannot validate plugin fingerprints or cache hit/miss counts.'
}
if ($usingLocalImplementation) {
    if (-not [IO.Path]::IsPathRooted($MSBuildCacheRepository)) {
        $MSBuildCacheRepository = Join-Path $repositoryRoot $MSBuildCacheRepository
    }
    $MSBuildCacheRepository = [IO.Path]::GetFullPath($MSBuildCacheRepository)
    if ($MSBuildCacheRepository -notmatch '^[A-Za-z]:[\\/]' -or $MSBuildCacheRepository.Contains(',')) {
        throw 'MSBuildCacheRepository must be an absolute local Windows drive path without commas.'
    }
    foreach ($project in @('src\Local\Microsoft.MSBuildCache.Local.csproj', 'src\SharedCompilation\Microsoft.MSBuildCache.SharedCompilation.csproj', 'Directory.Build.props', 'version.json', 'nuget.config')) {
        if (-not (Test-Path -LiteralPath (Join-Path $MSBuildCacheRepository $project) -PathType Leaf)) {
            throw "MSBuildCacheRepository is not a supported MSBuildCache source checkout: missing $project in $MSBuildCacheRepository"
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

function Get-JsonProperty($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Initialize-ProjectNetwork([string] $Name, [string[]] $Servers) {
    $ownershipLabel = 'com.pawel.msbuildcachetesting.managed'
    $dnsOption = 'com.docker.network.windowsshim.dnsservers'
    $gatewayDnsOption = 'com.docker.network.windowsshim.disable_gatewaydns'
    $serverList = $Servers -join ','
    $networkNames = @(& docker @dockerPrefix network ls --format '{{.Name}}')
    if ($LASTEXITCODE -ne 0) { throw 'Could not list Docker networks.' }
    if ($networkNames -contains $Name) {
        $networkJson = (& docker @dockerPrefix network inspect $Name | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "Could not inspect Docker network '$Name'." }
        $network = @($networkJson | ConvertFrom-Json)[0]
        if ((Get-JsonProperty $network.Labels $ownershipLabel) -ne 'true') {
            throw "Docker network '$Name' is not owned by this test repository. Choose another -NetworkName."
        }
        if ($network.Driver -ne 'nat') { throw "Owned Docker network '$Name' must use the nat driver." }
        $existingServers = [string](Get-JsonProperty $network.Options $dnsOption)
        $gatewayDnsDisabled = (Get-JsonProperty $network.Options $gatewayDnsOption) -eq 'true'
        if ($existingServers -eq $serverList -and $gatewayDnsDisabled) { return }
        if ($null -ne $network.Containers -and @($network.Containers.PSObject.Properties).Count -gt 0) {
            throw "Owned Docker network '$Name' needs updated DNS settings but still has attached containers. Retry after those builds finish."
        }
        Write-Host "Refreshing idle project network '$Name' for DNS $serverList"
        & docker @dockerPrefix network rm $Name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not remove idle owned Docker network '$Name'." }
    }
    Write-Host "Creating project NAT network '$Name' with DNS $serverList"
    & docker @dockerPrefix network create --driver nat --label "${ownershipLabel}=true" --opt "${dnsOption}=$serverList" --opt "${gatewayDnsOption}=true" $Name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create Docker network '$Name'." }
}

if (-not $DnsServers -or $DnsServers.Count -eq 0) {
    try {
        $DnsServers = @(
            Get-NetIPConfiguration -ErrorAction Stop |
                Where-Object { $null -ne $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
                Sort-Object InterfaceIndex |
                ForEach-Object { Get-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop } |
                ForEach-Object { $_.ServerAddresses } |
                Where-Object { -not [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($_)) } |
                Select-Object -Unique
        )
    }
    catch { throw "Could not infer active IPv4 DNS servers. Supply -DnsServers explicitly. $($_.Exception.Message)" }
}
$validatedServers = [Collections.Generic.List[string]]::new()
foreach ($server in $DnsServers) {
    $address = $null
    if (-not [Net.IPAddress]::TryParse($server, [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        [Net.IPAddress]::IsLoopback($address) -or $address.Equals([Net.IPAddress]::Any)) {
        throw "DNS servers must be reachable, non-loopback IPv4 literals: '$server'"
    }
    if (-not $validatedServers.Contains($address.ToString())) { $validatedServers.Add($address.ToString()) }
}
if ($validatedServers.Count -eq 0) { throw 'No active IPv4 DNS servers were found. Supply -DnsServers explicitly.' }
Initialize-ProjectNetwork $NetworkName $validatedServers.ToArray()
Write-Host "Docker network: $NetworkName | DNS: $($validatedServers -join ', ')"

$imageName = 'pawel-msbuildcachetesting:windows-local'
if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    $runName = '{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $ResultsDirectory = Join-Path $repositoryRoot "artifacts/docker/$runName"
}
elseif (-not [IO.Path]::IsPathRooted($ResultsDirectory)) {
    $ResultsDirectory = Join-Path $repositoryRoot $ResultsDirectory
}
if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
    $cacheFolder = if ($usingLocalImplementation) { 'LocalMSBuildCache\Local' } else { 'LocalMSBuildCache' }
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
    'run', '--name', $containerName, '--isolation', 'process', '--network', $NetworkName,
    '--mount', "type=bind,source=$ResultsDirectory,target=C:\results",
    '--mount', "type=bind,source=$CacheDirectory,target=C:\MSBuildCache"
)
if ($usingLocalImplementation) {
    $runArguments += @('--mount', "type=bind,source=$MSBuildCacheRepository,target=C:\cache-source,readonly")
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
if ($usingLocalImplementation) { $runArguments += @('-MSBuildCacheRepository', 'C:\cache-source') }
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
    & docker @dockerPrefix build --isolation process --memory 4g --network $NetworkName --file (Join-Path $repositoryRoot 'Dockerfile') --tag $imageName $repositoryRoot
    if ($LASTEXITCODE -ne 0) { throw "Docker image build failed (exit $LASTEXITCODE)." }

    Write-Host 'Running a fresh Windows traversal build; MSBuild memory sampling is always enabled.'
    Write-Host "Cache mode: $CacheMode | Cache universe: $CacheUniverse"
    if ($usingLocalImplementation) {
        Write-Host "Local implementation: $MSBuildCacheRepository (read-only source; built inside the container before measurement)"
        if ([string]::IsNullOrWhiteSpace($CacheUniverse)) { Write-Host 'Cache universe will be derived from the freshly built plugin/helper hashes.' }
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
