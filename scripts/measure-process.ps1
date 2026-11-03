#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Executable,
    [string[]] $ExecutableArguments = @(),
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $WorkingDirectory,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResultsDirectory,
    [string] $LogFile,
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [ValidateRange(1, 256)]
    [int] $MaxCpuCount = 2,
    [ValidateRange(1, 3600)]
    [int] $SampleSeconds = 2,
    [ValidateNotNullOrEmpty()]
    [string] $CacheUniverse = 'published-0.1.340-preview-v1',
    [ValidateSet('Enabled', 'Disabled')]
    [string] $CacheMode = 'Enabled'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'This process memory sampler requires Windows.' }

# Enumerate parent IDs without depending on the WMI service in the container.
if (-not ('BuildProcessTree' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class BuildProcessTree
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size, Usage, ProcessId;
        public UIntPtr DefaultHeap;
        public uint ModuleId, Threads, ParentProcessId;
        public int BasePriority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    public static Dictionary<int, int> ParentIds()
    {
        IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            var result = new Dictionary<int, int>();
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
            if (!Process32FirstW(snapshot, ref entry)) throw new Win32Exception(Marshal.GetLastWin32Error());
            do { result[(int)entry.ProcessId] = (int)entry.ParentProcessId; }
            while (Process32NextW(snapshot, ref entry));
            int error = Marshal.GetLastWin32Error();
            if (error != 18) throw new Win32Exception(error);
            return result;
        }
        finally { CloseHandle(snapshot); }
    }
}
'@
}

New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
if ([string]::IsNullOrWhiteSpace($LogFile)) { $LogFile = Join-Path $ResultsDirectory 'build.log' }
New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($LogFile))) -Force | Out-Null
$csvPath = Join-Path $ResultsDirectory 'memory.csv'
$summaryPath = Join-Path $ResultsDirectory 'memory-summary.json'
if (Test-Path -LiteralPath $summaryPath) { Remove-Item -LiteralPath $summaryPath }
$writer = [IO.StreamWriter]::new($csvPath, $false, [Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
$writer.WriteLine('timestamp_utc,elapsed_seconds,build_tree_private_bytes,build_tree_working_set_bytes,process_count,skipped_process_count')
$logWriter = [IO.StreamWriter]::new($LogFile, $false, [Text.UTF8Encoding]::new($false))
$logWriter.AutoFlush = $true
$timer = [Diagnostics.Stopwatch]::new()
$knownBuildProcesses = [Collections.Generic.Dictionary[int, long]]::new()
$memoryState = [pscustomobject]@{
    SampleCount = 0
    PeakPrivateBytes = 0L
    PeakWorkingSetBytes = 0L
    MaximumSkippedProcesses = 0
    SamplingFailed = $false
}
$buildProcess = $null
$processStarted = $false
$processElapsedSeconds = $null

function Write-MemorySample {
    $privateBytes = 0L
    $workingSetBytes = 0L
    $processCount = 0
    $skippedProcessCount = 0
    if ($null -ne $buildProcess) {
        $parents = [BuildProcessTree]::ParentIds()
        $treeIds = [Collections.Generic.HashSet[int]]::new()
        # Retain observed descendants if an intermediate parent exits. Check start
        # times to avoid including an unrelated process after PID reuse.
        foreach ($entry in @($knownBuildProcesses.GetEnumerator())) {
            $candidate = $null
            try {
                $candidate = [Diagnostics.Process]::GetProcessById($entry.Key)
                if ($candidate.StartTime.ToUniversalTime().Ticks -eq $entry.Value) { $null = $treeIds.Add($entry.Key) }
                else { $null = $knownBuildProcesses.Remove($entry.Key) }
            }
            catch { $null = $knownBuildProcesses.Remove($entry.Key) }
            finally { if ($null -ne $candidate) { $candidate.Dispose() } }
        }
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($entry in $parents.GetEnumerator()) {
                if ($treeIds.Contains($entry.Value) -and $treeIds.Add($entry.Key)) { $changed = $true }
            }
        }
        foreach ($processId in $treeIds) {
            $sampledProcess = $null
            try {
                $sampledProcess = [Diagnostics.Process]::GetProcessById($processId)
                $sampledProcess.Refresh()
                $knownBuildProcesses[$processId] = $sampledProcess.StartTime.ToUniversalTime().Ticks
                $privateBytes += $sampledProcess.PrivateMemorySize64
                $workingSetBytes += $sampledProcess.WorkingSet64
                $processCount++
            }
            catch { $skippedProcessCount++ }
            finally { if ($null -ne $sampledProcess) { $sampledProcess.Dispose() } }
        }
    }
    $memoryState.SampleCount++
    $memoryState.PeakPrivateBytes = [Math]::Max($memoryState.PeakPrivateBytes, $privateBytes)
    $memoryState.PeakWorkingSetBytes = [Math]::Max($memoryState.PeakWorkingSetBytes, $workingSetBytes)
    $memoryState.MaximumSkippedProcesses = [Math]::Max($memoryState.MaximumSkippedProcesses, $skippedProcessCount)
    $elapsed = $timer.Elapsed.TotalSeconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)
    $writer.WriteLine(('{0},{1},{2},{3},{4},{5}' -f
        [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'), $elapsed,
        $privateBytes, $workingSetBytes, $processCount, $skippedProcessCount))
    Write-Host ('[memory {0:mm\:ss}] build tree private {1,8:N1} MiB | working sets {2,8:N1} MiB | processes {3,3} | peak private {4,8:N1} MiB' -f
        $timer.Elapsed, ($privateBytes / 1MB), ($workingSetBytes / 1MB), $processCount, ($memoryState.PeakPrivateBytes / 1MB))
}

function Write-AvailableProcessOutput([psobject] $State) {
    foreach ($streamName in @('StdOut', 'StdErr')) {
        $taskProperty = "${streamName}Task"
        $readerProperty = "${streamName}Reader"
        $doneProperty = "${streamName}Done"
        # Yield to the sampling loop even if a child continuously writes output.
        $linesRead = 0
        while ($linesRead -lt 64 -and -not $State.$doneProperty -and $State.$taskProperty.IsCompleted) {
            $line = $State.$taskProperty.GetAwaiter().GetResult()
            $linesRead++
            if ($null -eq $line) { $State.$doneProperty = $true }
            else {
                Write-Host $line
                $logWriter.WriteLine($line)
                $State.$taskProperty = $State.$readerProperty.ReadLineAsync()
            }
        }
    }
}

Write-Host "Memory is always sampled every ${SampleSeconds}s during the actual MSBuild restore and build."
Write-Host 'Primary metric: summed private allocated bytes for the measured executable and descendants, including MSBuild workers and compilers.'
Write-Host 'Summed working sets may double-count shared pages. Neither metric measures retained managed heap or whole-container memory.'
Write-Host "CSV: $csvPath"
$buildExitCode = 1
try {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $WorkingDirectory
    foreach ($argument in $ExecutableArguments) { $startInfo.ArgumentList.Add($argument) }
    $buildProcess = [Diagnostics.Process]::new()
    $buildProcess.StartInfo = $startInfo
    $timer.Start()
    if (-not $buildProcess.Start()) { throw 'Could not start the build process.' }
    $processStarted = $true
    $knownBuildProcesses[$buildProcess.Id] = $buildProcess.StartTime.ToUniversalTime().Ticks
    $outputState = [pscustomobject]@{
        StdOutReader = $buildProcess.StandardOutput
        StdErrReader = $buildProcess.StandardError
        StdOutTask = $buildProcess.StandardOutput.ReadLineAsync()
        StdErrTask = $buildProcess.StandardError.ReadLineAsync()
        StdOutDone = $false
        StdErrDone = $false
    }
    try { Write-MemorySample }
    catch {
        $memoryState.SamplingFailed = $true
        throw
    }
    $nextSampleSeconds = $timer.Elapsed.TotalSeconds + $SampleSeconds
    while (-not ($buildProcess.HasExited -and $outputState.StdOutDone -and $outputState.StdErrDone)) {
        Write-AvailableProcessOutput $outputState
        if ($timer.Elapsed.TotalSeconds -ge $nextSampleSeconds) {
            try { Write-MemorySample }
            catch {
                $memoryState.SamplingFailed = $true
                throw
            }
            $nextSampleSeconds = $timer.Elapsed.TotalSeconds + $SampleSeconds
        }
        if (-not $buildProcess.HasExited) { $null = $buildProcess.WaitForExit(100) }
        elseif (-not ($outputState.StdOutDone -and $outputState.StdErrDone)) { Start-Sleep -Milliseconds 10 }
    }
    $buildProcess.WaitForExit()
    $buildExitCode = $buildProcess.ExitCode
}
catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    $logWriter.WriteLine($_.Exception.ToString())
    if ($processStarted -and -not $buildProcess.HasExited) {
        $buildProcess.Kill($true)
        $buildProcess.WaitForExit()
    }
}
finally {
    if ($processStarted -and $buildProcess.HasExited) {
        $processElapsedSeconds = [Math]::Round(($buildProcess.ExitTime - $buildProcess.StartTime).TotalSeconds, 3)
    }
    try { Write-MemorySample }
    catch {
        $memoryState.SamplingFailed = $true
        Write-Error -ErrorRecord $_ -ErrorAction Continue
        if ($buildExitCode -eq 0) { $buildExitCode = 1 }
    }
    $timer.Stop()
    try {
        [ordered]@{
            schemaVersion = 2
            exitCode = $buildExitCode
            configuration = $Configuration
            maxCpuCount = $MaxCpuCount
            cacheMode = $CacheMode
            cacheUniverse = $CacheUniverse
            sampleIntervalSeconds = $SampleSeconds
            sampleCount = $memoryState.SampleCount
            elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
            processElapsedSeconds = $processElapsedSeconds
            executable = $Executable
            privateBytesMetric = 'sum-of-build-process-tree-PrivateMemorySize64'
            workingSetMetric = 'sum-of-build-process-tree-WorkingSet64'
            peakSampledBuildTreePrivateBytes = $memoryState.PeakPrivateBytes
            peakSampledBuildTreeWorkingSetBytes = $memoryState.PeakWorkingSetBytes
            maximumSkippedProcesses = $memoryState.MaximumSkippedProcesses
            samplingFailed = $memoryState.SamplingFailed
            scope = 'Actual measured executable and observed descendants during MSBuild restore and build. Excludes the PowerShell orchestrator, preparation, post-build verification, sampler and unrelated container processes.'
            notes = 'Private bytes measure private allocated memory, not private resident working set. Summed working sets may double-count shared pages. Samples may miss short-lived processes and spikes. Neither metric measures retained managed heap or whole-container memory.'
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM
    }
    finally {
        $writer.Dispose()
        $logWriter.Dispose()
        if ($null -ne $buildProcess) { $buildProcess.Dispose() }
    }
    Write-Host ('Memory summary: exit {0}, elapsed {1:N1}s, peak sampled build tree private {2:N1} MiB, peak summed working sets {3:N1} MiB' -f
        $buildExitCode, $timer.Elapsed.TotalSeconds, ($memoryState.PeakPrivateBytes / 1MB), ($memoryState.PeakWorkingSetBytes / 1MB))
    Write-Host "Saved $csvPath and $summaryPath"
}
exit $buildExitCode
