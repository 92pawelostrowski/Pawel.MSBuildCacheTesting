#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidateRange(1, 256)]
    [int] $MaxCpuCount = 2,

    [string] $LogDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$repoRoot = $PSScriptRoot

function Assert-NativeSuccess([string] $Operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

Push-Location -LiteralPath $repoRoot
try {
    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = Join-Path $repoRoot 'artifacts/logs/native'
    }
    $LogDirectory = [System.IO.Path]::GetFullPath($LogDirectory)
    $null = New-Item -ItemType Directory -Path $LogDirectory -Force
    $summaryPath = Join-Path $LogDirectory 'build-summary.json'
    if (Test-Path -LiteralPath $summaryPath) {
        Remove-Item -LiteralPath $summaryPath
    }

    & (Join-Path $repoRoot 'scripts/generate.ps1') -VerifyOnly
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'workload.json') -Raw | ConvertFrom-Json -Depth 64
    if ($manifest.graph.projectCount -ne 500 -or $manifest.graph.projectReferenceCount -ne 4750) {
        throw 'The checked-in workload must contain exactly 500 projects and 4,750 project-to-project references.'
    }

    $sdkVersion = (& dotnet --version | Out-String).Trim()
    Assert-NativeSuccess 'Resolving the pinned .NET SDK'
    Write-Host "Building $($manifest.graph.projectCount) projects / $($manifest.graph.projectReferenceCount) project references"
    Write-Host "SDK: $sdkVersion | Configuration: $Configuration | Maximum build workers: $MaxCpuCount"
    Write-Host 'MSBuildCache: package referenced; caching DISABLED'
    Write-Host "Logs: $LogDirectory"

    $arguments = @(
        'msbuild',
        'dirs.proj',
        '-restore',
        '-graphBuild',
        "-maxCpuCount:$MaxCpuCount",
        '-nodeReuse:false',
        "-property:Configuration=$Configuration",
        '-property:MSBuildCacheEnabled=false',
        "-binaryLogger:$(Join-Path $LogDirectory 'build.binlog');ProjectImports=None",
        '-verbosity:minimal',
        '-nologo'
    )
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    & dotnet @arguments 2>&1 | Tee-Object -FilePath (Join-Path $LogDirectory 'build.log')
    Assert-NativeSuccess 'Traversal restore/build'

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

    $evaluationArguments = @(
        'msbuild', $manifest.projects[0].path,
        "-property:Configuration=$Configuration",
        '-getProperty:MSBuildCacheEnabled',
        '-getItem:ProjectCachePlugin',
        '-getItem:PackageReference',
        '-getItem:PackageVersion',
        '-nologo'
    )
    $evaluationText = (& dotnet @evaluationArguments | Out-String)
    Assert-NativeSuccess 'Checking the evaluated plugin configuration'
    $evaluationText | Set-Content -LiteralPath (Join-Path $LogDirectory 'plugin-state.json') -Encoding utf8NoBOM
    $evaluation = $evaluationText | ConvertFrom-Json -Depth 64
    if ($evaluation.Properties.MSBuildCacheEnabled -ne 'false' -or @($evaluation.Items.ProjectCachePlugin).Count -ne 0) {
        throw 'Expected MSBuildCacheEnabled=false and no registered ProjectCachePlugin.'
    }
    $pluginReferences = @($evaluation.Items.PackageReference | Where-Object Identity -eq 'Microsoft.MSBuildCache.Local')
    if ($pluginReferences.Count -ne 1) {
        throw 'The latest published Microsoft.MSBuildCache.Local package must remain referenced.'
    }
    $pluginVersions = @($evaluation.Items.PackageVersion | Where-Object Identity -eq 'Microsoft.MSBuildCache.Local')
    if ($pluginVersions.Count -ne 1 -or $pluginVersions[0].Version -ne '0.1.340-preview') {
        throw 'Expected the pinned published baseline Microsoft.MSBuildCache.Local 0.1.340-preview.'
    }

    $verificationAssembly = Join-Path $repoRoot ($manifest.verification.assemblyPath.Replace('{configuration}', $Configuration))
    & dotnet $verificationAssembly 2>&1 | Tee-Object -FilePath (Join-Path $LogDirectory 'verification.log')
    Assert-NativeSuccess 'Running the workload verification application'
    $timer.Stop()

    $summary = [ordered]@{
        schemaVersion = 1
        sdkVersion = $sdkVersion
        configuration = $Configuration
        projectCount = $manifest.graph.projectCount
        projectReferenceCount = $manifest.graph.projectReferenceCount
        implicitTransitiveProjectReferences = $false
        verifiedPrimaryAssemblies = @($manifest.projects).Count
        msbuildCacheEnabled = $false
        msbuildCachePackageVersion = $pluginVersions[0].Version
        registeredCachePlugins = 0
        verificationExpectedValue = $manifest.verification.expectedValue
        elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        succeeded = $true
    }
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM
    Write-Host "PASS: all 500 assemblies exist, the verification application passed, and no cache plugin was registered."
    Write-Host ("Elapsed: {0:N1} seconds" -f $timer.Elapsed.TotalSeconds)
}
finally {
    Pop-Location
}
