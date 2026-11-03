#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $PackageDirectory,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PackageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $PackageDirectory -PathType Container)) {
    throw "Package directory does not exist: $PackageDirectory"
}
if ((Test-Path -LiteralPath $OutputDirectory) -and @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) {
    throw "Package preparation requires an empty output directory: $OutputDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

function Get-StreamSha256([IO.Stream] $Stream) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($hasher.ComputeHash($Stream)).ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

# Copy only the selected packages so this run keeps an immutable input snapshot
# even if the caller rebuilds the packages in the supplied directory later.
$packageVersion = ''
Add-Type -AssemblyName System.IO.Compression.FileSystem
$packages = @(foreach ($id in @('Microsoft.MSBuildCache.Local', 'Microsoft.MSBuildCache.SharedCompilation')) {
    $packageFiles = @(Get-ChildItem -LiteralPath $PackageDirectory -Filter "$id.*.nupkg" -File)
    if ($packageFiles.Count -ne 1) { throw "Expected exactly one $id package in $PackageDirectory" }
    $fileName = $packageFiles[0].Name
    $packagePath = Join-Path $OutputDirectory $fileName
    Copy-Item -LiteralPath $packageFiles[0].FullName -Destination $packagePath
    $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        $nuspecs = @($archive.Entries | Where-Object FullName -Like '*.nuspec')
        if ($nuspecs.Count -ne 1) { throw "Expected one package manifest in $fileName" }
        $reader = [IO.StreamReader]::new($nuspecs[0].Open())
        try { [xml] $nuspec = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $actualVersion = [string] $nuspec.package.metadata.version
        if ([string]::IsNullOrWhiteSpace($packageVersion)) { $packageVersion = $actualVersion }
        if ($nuspec.package.metadata.id -cne $id -or [string]::IsNullOrWhiteSpace($actualVersion) -or $actualVersion -cne $packageVersion) {
            throw "Local and SharedCompilation packages must have the expected IDs and the same version: $fileName"
        }
        $assembly = $archive.GetEntry("build/net472/$id.dll")
        if ($null -eq $assembly -or $assembly.Length -eq 0) { throw "The net472 assembly is missing from $fileName" }
        $assemblyStream = $assembly.Open()
        try { $assemblyHash = Get-StreamSha256 $assemblyStream } finally { $assemblyStream.Dispose() }
        if ($id -eq 'Microsoft.MSBuildCache.Local') {
            $rocksDb = $archive.GetEntry('build/net472/native/amd64/rocksdb.dll')
            if ($null -eq $rocksDb -or $rocksDb.Length -eq 0) { throw "Native RocksDB is missing from $fileName" }
        }
        [ordered]@{
            id = $id
            fileName = $fileName
            sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
            assemblySha256 = $assemblyHash
        }
    }
    finally { $archive.Dispose() }
})
$packageIdentity = ($packages | ForEach-Object { $_.sha256 }) -join '|'
$identityStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($packageIdentity))
try { $cacheUniverse = 'local-' + (Get-StreamSha256 $identityStream).Substring(0, 20) } finally { $identityStream.Dispose() }

# Exact package-ID mappings keep the supplied plugins on this file feed; other
# workload dependencies continue to restore from nuget.org.
$escapedFeed = [Security.SecurityElement]::Escape($OutputDirectory)
@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources><clear /><add key="LocalMSBuildCache" value="$escapedFeed" /><add key="nuget.org" value="https://api.nuget.org/v3/index.json" /></packageSources>
  <packageSourceMapping>
    <packageSource key="LocalMSBuildCache"><package pattern="Microsoft.MSBuildCache.Local" /><package pattern="Microsoft.MSBuildCache.SharedCompilation" /></packageSource>
    <packageSource key="nuget.org"><package pattern="*" /></packageSource>
  </packageSourceMapping>
</configuration>
"@ | Set-Content -LiteralPath (Join-Path $OutputDirectory 'NuGet.config') -Encoding utf8NoBOM
$manifestPath = Join-Path $OutputDirectory 'manifest.json'
[ordered]@{
    schemaVersion = 1
    packageVersion = $packageVersion
    localPluginAssemblySha256 = $packages[0].assemblySha256
    sharedCompilationAssemblySha256 = $packages[1].assemblySha256
    cacheUniverse = $cacheUniverse
    packages = $packages
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
Write-Host "Using supplied MSBuildCache packages $packageVersion. Cache universe: $cacheUniverse"
Write-Output $manifestPath
