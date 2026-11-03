#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $RepositoryPath,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'Local package preparation requires the Windows toolchain container.' }
foreach ($command in @('robocopy', 'git', 'dotnet')) { Get-Command $command -ErrorAction Stop | Out-Null }
$RepositoryPath = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\', '/')
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
$snapshotPath = 'C:\local-msbuildcache'
$Configuration = 'Release'
$packageVersion = ''
$packageIds = @('Microsoft.MSBuildCache.Local', 'Microsoft.MSBuildCache.SharedCompilation')
foreach ($project in @('Local', 'SharedCompilation')) {
    $projectPath = Join-Path $RepositoryPath "src\$project\Microsoft.MSBuildCache.$project.csproj"
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) { throw "MSBuildCache project is missing: $projectPath" }
}
foreach ($path in @($RepositoryPath, $OutputDirectory, $snapshotPath)) {
    foreach ($other in @($RepositoryPath, $OutputDirectory, $snapshotPath)) {
        if ($path -ne $other -and $path.StartsWith($other + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The source repository, source snapshot and package output paths must be separate.'
        }
    }
}
if ($RepositoryPath -ieq $OutputDirectory -or $RepositoryPath -ieq $snapshotPath -or $OutputDirectory -ieq $snapshotPath) {
    throw 'The source repository, source snapshot and package output paths must be separate.'
}
foreach ($path in @($snapshotPath, $OutputDirectory)) {
    if ((Test-Path -LiteralPath $path) -and @(Get-ChildItem -LiteralPath $path -Force).Count -gt 0) {
        throw "Package preparation requires an empty directory: $path"
    }
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}
$buildLog = Join-Path $OutputDirectory 'local-build.log'
[IO.File]::WriteAllText($buildLog, '', [Text.UTF8Encoding]::new($false))

function Invoke-CheckedNative([string] $Executable, [string[]] $Arguments, [int[]] $AllowedExitCodes = @(0)) {
    Write-Host "> $Executable $($Arguments -join ' ')"
    & $Executable @Arguments 2>&1 | ForEach-Object { $_.ToString() } |
        Tee-Object -FilePath $buildLog -Append | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -notin $AllowedExitCodes) {
        throw "$Executable failed with exit code $LASTEXITCODE. See $buildLog"
    }
}
function Get-StreamSha256([IO.Stream] $Stream) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($hasher.ComputeHash($Stream)).ToLowerInvariant() }
    finally { $hasher.Dispose() }
}
function Add-FrameworkReferenceSource([xml] $Config) {
    $sources = $Config.SelectSingleNode('/configuration/packageSources')
    if ($null -eq $sources) { throw 'The copied nuget.config must declare packageSources.' }
    $originalSources = @($sources.SelectNodes('add'))
    $disabledSources = @($Config.SelectNodes('/configuration/disabledPackageSources/add') | Where-Object { $_.GetAttribute('value') -ieq 'true' })
    $sourceKey = 'LocalBuildNuGetOrg'
    $suffix = 0
    while ($true) {
        $existing = @($originalSources | Where-Object { $_.GetAttribute('key') -ieq $sourceKey })
        $disabled = @($disabledSources | Where-Object { $_.GetAttribute('key') -ieq $sourceKey }).Count -gt 0
        if ($existing.Count -eq 0) {
            $source = $Config.CreateElement('add')
            $source.SetAttribute('key', $sourceKey)
            $source.SetAttribute('value', 'https://api.nuget.org/v3/index.json')
            [void] $sources.AppendChild($source)
            break
        }
        if ($existing[0].GetAttribute('value') -ieq 'https://api.nuget.org/v3/index.json' -and -not $disabled) { break }
        $suffix++
        $sourceKey = "LocalBuildNuGetOrg$suffix"
    }
    $mapping = $Config.SelectSingleNode('/configuration/packageSourceMapping')
    if ($null -eq $mapping) {
        $mapping = $Config.CreateElement('packageSourceMapping')
        [void] $Config.DocumentElement.AppendChild($mapping)
        foreach ($source in $originalSources) {
            $key = $source.GetAttribute('key')
            if (@($disabledSources | Where-Object { $_.GetAttribute('key') -ieq $key }).Count -gt 0) { continue }
            $entry = $Config.CreateElement('packageSource')
            $entry.SetAttribute('key', $key)
            $pattern = $Config.CreateElement('package')
            $pattern.SetAttribute('pattern', '*')
            [void] $entry.AppendChild($pattern)
            [void] $mapping.AppendChild($entry)
        }
    }
    $entry = @($mapping.SelectNodes('packageSource') | Where-Object { $_.GetAttribute('key') -ieq $sourceKey })
    if ($entry.Count -eq 0) {
        $entry = $Config.CreateElement('packageSource')
        $entry.SetAttribute('key', $sourceKey)
        [void] $mapping.AppendChild($entry)
    }
    else { $entry = $entry[0] }
    foreach ($frameworkPattern in @('Microsoft.NETFramework.ReferenceAssemblies*', 'Microsoft.NETCore.App.*', 'Microsoft.AspNetCore.App.*', 'Microsoft.WindowsDesktop.App.*')) {
        if (@($entry.SelectNodes('package') | Where-Object { $_.GetAttribute('pattern') -ieq $frameworkPattern }).Count -eq 0) {
            $pattern = $Config.CreateElement('package')
            $pattern.SetAttribute('pattern', $frameworkPattern)
            [void] $entry.AppendChild($pattern)
        }
    }
}

# Copy working files, including local edits, into a writable container-only tree.
# Exclude .git as both a directory and a worktree pointer file.
Invoke-CheckedNative 'robocopy' @(
    $RepositoryPath, $snapshotPath, '/E', '/XJ', '/R:1', '/W:1', '/NFL', '/NDL',
    '/XD', '.git', '.vs', '.vscode', 'artifacts', 'bin', 'obj', '.nuget', 'TestResults', 'TestResult',
    '/XF', '.git'
) (0..7)
$snapshotNugetPath = Join-Path $snapshotPath 'nuget.config'
if (-not (Test-Path -LiteralPath $snapshotNugetPath -PathType Leaf)) { throw "The source checkout must provide $snapshotNugetPath" }
[xml] $snapshotNugetConfig = [IO.File]::ReadAllText($snapshotNugetPath)
Add-FrameworkReferenceSource $snapshotNugetConfig
$snapshotNugetConfig.Save($snapshotNugetPath)
Write-Host 'Automatic .NET Framework and .NET SDK framework packs come from nuget.org; other source feeds and mappings are preserved.'
Invoke-CheckedNative 'git' @('-C', $snapshotPath, 'init', '--quiet', '--initial-branch=main')
Invoke-CheckedNative 'git' @('-C', $snapshotPath, '-c', 'core.autocrlf=false', 'add', '--all')
$previousAuthorDate = $env:GIT_AUTHOR_DATE
$previousCommitterDate = $env:GIT_COMMITTER_DATE
try {
    $env:GIT_AUTHOR_DATE = '2000-01-01T00:00:00Z'
    $env:GIT_COMMITTER_DATE = '2000-01-01T00:00:00Z'
    Invoke-CheckedNative 'git' @(
        '-C', $snapshotPath, '-c', 'user.name=MSBuildCache Local Fixture',
        '-c', 'user.email=msbuildcache-local@localhost', 'commit', '--quiet', '--message=Local source snapshot'
    )
}
finally {
    $env:GIT_AUTHOR_DATE = $previousAuthorDate
    $env:GIT_COMMITTER_DATE = $previousCommitterDate
}
$snapshotCommit = (& git -C $snapshotPath rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $snapshotCommit -notmatch '^[0-9a-f]{40}$') { throw 'Could not identify the local source snapshot.' }

# GeneratePackageOnBuild already packs these projects. Disable reusable workers
# and compiler servers so preparation cannot contaminate the measured build tree.
Push-Location -LiteralPath $snapshotPath
try {
    foreach ($project in @('Local', 'SharedCompilation')) {
        Invoke-CheckedNative 'dotnet' @(
            'build', "src\$project\Microsoft.MSBuildCache.$project.csproj", '--configuration', $Configuration,
            '--disable-build-servers', '-nodeReuse:false', '-property:UseSharedCompilation=false',
            '-property:TargetFrameworks=net472',
            '-property:SignType=Test',
            "-property:PackageOutputPath=$OutputDirectory", '-property:NuGetInteractive=false'
        )
    }
}
finally { Pop-Location }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$packages = @(foreach ($id in $packageIds) {
    # The output folder started empty. Read the version produced by the repo's
    # own versioning targets rather than guessing it or selecting old artifacts.
    $matchingPackages = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter "$id.*.nupkg" -File)
    if ($matchingPackages.Count -ne 1) { throw "Expected exactly one freshly built package for $id in $OutputDirectory" }
    $fileName = $matchingPackages[0].Name
    $packagePath = $matchingPackages[0].FullName
    $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        $nuspecs = @($archive.Entries | Where-Object FullName -Like '*.nuspec')
        if ($nuspecs.Count -ne 1) { throw "Expected one package manifest in $fileName" }
        $reader = [IO.StreamReader]::new($nuspecs[0].Open())
        try { [xml] $nuspec = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $actualVersion = [string] $nuspec.package.metadata.version
        if ([string]::IsNullOrWhiteSpace($packageVersion)) { $packageVersion = $actualVersion }
        if ($nuspec.package.metadata.id -cne $id -or [string]::IsNullOrWhiteSpace($actualVersion) -or $actualVersion -cne $packageVersion) {
            throw "Package identity does not match the requested local build: $fileName"
        }
        $assembly = $archive.GetEntry("build/net472/$id.dll")
        if ($null -eq $assembly -or $assembly.Length -eq 0) { throw "The net472 assembly is missing from $fileName" }
        $assemblyStream = $assembly.Open()
        try { $assemblyHash = Get-StreamSha256 $assemblyStream } finally { $assemblyStream.Dispose() }
        if ($id -eq 'Microsoft.MSBuildCache.Local') {
            $rocksDb = $archive.GetEntry('build/net472/native/amd64/rocksdb.dll')
            if ($null -eq $rocksDb -or $rocksDb.Length -eq 0) { throw "Native RocksDB is missing from $fileName" }
        }
        [ordered]@{ id = $id; fileName = $fileName; sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant(); assemblySha256 = $assemblyHash }
    }
    finally { $archive.Dispose() }
})
$identityStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($packages[0].assemblySha256 + '|' + $packages[1].assemblySha256))
try { $cacheUniverse = 'local-' + (Get-StreamSha256 $identityStream).Substring(0, 20) } finally { $identityStream.Dispose() }
$nugetConfigPath = Join-Path $OutputDirectory 'NuGet.config'
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
"@ | Set-Content -LiteralPath $nugetConfigPath -Encoding utf8NoBOM
$manifestPath = Join-Path $OutputDirectory 'manifest.json'
[ordered]@{
    schemaVersion = 1
    packageVersion = $packageVersion
    configuration = $Configuration
    sourceSnapshotCommit = $snapshotCommit
    localPluginAssemblySha256 = $packages[0].assemblySha256
    sharedCompilationAssemblySha256 = $packages[1].assemblySha256
    cacheUniverse = $cacheUniverse
    nugetConfigPath = $nugetConfigPath
    packages = $packages
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
Write-Host "Local MSBuildCache packages prepared. Cache universe: $cacheUniverse"
Write-Output $manifestPath
