#requires -Version 7.0
[CmdletBinding()]
param(
    [switch] $VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/')
$inputRoot = Join-Path $repoRoot 'workload-inputs'
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'workload.json') -Raw | ConvertFrom-Json -Depth 64
$settings = $manifest.strongFingerprintWorkload
if (-not $settings.enabled) {
    throw 'The generated workload manifest must enable strongFingerprintWorkload.'
}
[int] $memberCount = $settings.directoryMemberCount
if ($memberCount -lt 1 -or $memberCount -gt 100000) {
    throw 'strongFingerprintWorkload.directoryMemberCount must be between 1 and 100000.'
}

function Get-InputPath([string] $RelativePath) {
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Workload input paths must be repository-relative: $RelativePath"
    }
    $path = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $RelativePath))
    if (-not $path.StartsWith($inputRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Workload input path must remain below workload-inputs: $RelativePath"
    }
    $ancestor = $path
    while (-not [string]::Equals($ancestor, $repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Workload inputs cannot use a reparse point: $ancestor"
            }
        }
        $ancestor = [System.IO.Path]::GetDirectoryName($ancestor)
    }
    return $path
}

$settingsPath = Get-InputPath $settings.settingsPath
$membersDirectory = Get-InputPath $settings.membersDirectory
$markerDirectory = Get-InputPath $settings.markerDirectory
$initializationMarkerPath = Get-InputPath $settings.initializationMarkerPath
if (-not $VerifyOnly -and (Test-Path -LiteralPath $initializationMarkerPath -PathType Leaf)) {
    Write-Host 'Strong-fingerprint inputs are initialized; preserving edits, additions, markers, and deletions.'
    return
}
$utf8 = [System.Text.UTF8Encoding]::new($false)
$expected = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
$expected.Add($settingsPath, (@($settings.settingsLines) -join "`n") + "`n")
$expected.Add((Join-Path $markerDirectory '.gitkeep'), '')
for ($member = 0; $member -lt $memberCount; $member++) {
    $number = $member.ToString('D6', [System.Globalization.CultureInfo]::InvariantCulture)
    $expected.Add((Join-Path $membersDirectory "member$number.member"), "member=$number`n")
}
if ($VerifyOnly) {
    $expected.Add($initializationMarkerPath, "format=1`n")
}

$differences = [System.Collections.Generic.List[string]]::new()
$createdCount = 0
foreach ($entry in $expected.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Key -PathType Leaf)) {
        if ($VerifyOnly) {
            $differences.Add("Missing: $([System.IO.Path]::GetRelativePath($repoRoot, $entry.Key))")
        }
        else {
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($entry.Key))
            [System.IO.File]::WriteAllText($entry.Key, $entry.Value, $utf8)
            $createdCount++
        }
        continue
    }

    if ($VerifyOnly -and -not [System.StringComparer]::Ordinal.Equals(
            [System.IO.File]::ReadAllText($entry.Key).Replace("`r`n", "`n"), $entry.Value)) {
        $differences.Add("Changed baseline content: $([System.IO.Path]::GetRelativePath($repoRoot, $entry.Key))")
    }
}

if ($VerifyOnly) {
    if (Test-Path -LiteralPath $membersDirectory) {
        foreach ($file in Get-ChildItem -LiteralPath $membersDirectory -File -Recurse -Force) {
            if (-not $expected.ContainsKey($file.FullName)) {
                $differences.Add("Unexpected baseline member: $([System.IO.Path]::GetRelativePath($repoRoot, $file.FullName))")
            }
        }
    }
    if (Test-Path -LiteralPath $markerDirectory) {
        foreach ($file in Get-ChildItem -LiteralPath $markerDirectory -File -Recurse -Force) {
            if (-not $expected.ContainsKey($file.FullName)) {
                $differences.Add("Baseline markers must be absent: $([System.IO.Path]::GetRelativePath($repoRoot, $file.FullName))")
            }
        }
    }
    if ($differences.Count -gt 0) {
        foreach ($difference in $differences) {
            Write-Host $difference
        }
        throw "Strong-fingerprint baseline differs in $($differences.Count) input(s)."
    }
    Write-Host "Verified strong-fingerprint baseline: $memberCount members, shared settings, and absent project markers."
}
else {
    [System.IO.File]::WriteAllText($initializationMarkerPath, "format=1`n", $utf8)
    Write-Host "Initialized strong-fingerprint inputs: $memberCount baseline members; created $createdCount missing files; preserved existing contents."
}
