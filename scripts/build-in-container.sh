#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

configuration="${CONFIGURATION:-Release}"
max_cpu_count="${MAX_CPU_COUNT:-2}"
sample_seconds="${MEMORY_SAMPLE_SECONDS:-2}"
results_directory="${RESULTS_DIRECTORY:-/results}"

if [[ ! "$configuration" =~ ^(Debug|Release)$ ]]; then
    echo "CONFIGURATION must be Debug or Release." >&2
    exit 2
fi
if [[ ! "$max_cpu_count" =~ ^[1-9][0-9]*$ || ! "$sample_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "MAX_CPU_COUNT and MEMORY_SAMPLE_SECONDS must be positive integers." >&2
    exit 2
fi
if ((max_cpu_count > 256 || sample_seconds > 3600)); then
    echo "MAX_CPU_COUNT must be at most 256; MEMORY_SAMPLE_SECONDS must be at most 3600." >&2
    exit 2
fi

mkdir -p "$results_directory" "$DOTNET_CLI_HOME" "$NUGET_PACKAGES" "$HOME"
csv_file="$results_directory/memory.csv"
summary_file="$results_directory/memory-summary.json"
printf '%s\n' 'timestamp_utc,elapsed_seconds,container_bytes,working_set_bytes,process_rss_bytes,kernel_peak_container_bytes' > "$csv_file"

metric_source="process-rss-sum"
if [[ -r /sys/fs/cgroup/memory.current ]]; then
    metric_source="cgroup-v2-current-minus-inactive-file"
elif [[ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]]; then
    metric_source="cgroup-v1-usage-minus-total-inactive-file"
fi

start_seconds=$SECONDS
sample_count=0
peak_working_set=0
peak_container=0
peak_process_rss=0
peak_kernel_container=0

sample_memory() {
    local container=0 inactive_file=0 working_set=0 rss_kib=0 process_rss=0 kernel_peak=0
    local metric value unit status_file timestamp elapsed

    # The container has its own PID namespace: this includes the build driver,
    # every MSBuild worker and compiler, and the small memory sampler itself.
    # Shared pages can be counted more than once in this supplementary RSS sum.
    for status_file in /proc/[0-9]*/status; do
        if [[ -r "$status_file" ]]; then
            while read -r metric value unit; do
                if [[ "$metric" == "VmRSS:" ]]; then
                    rss_kib=$((rss_kib + value))
                    break
                fi
            done 2>/dev/null < "$status_file" || true
        fi
    done
    process_rss=$((rss_kib * 1024))

    case "$metric_source" in
        cgroup-v2-*)
            read -r container < /sys/fs/cgroup/memory.current
            while read -r metric value; do
                if [[ "$metric" == "inactive_file" ]]; then inactive_file=$value; break; fi
            done < /sys/fs/cgroup/memory.stat
            if [[ -r /sys/fs/cgroup/memory.peak ]]; then
                read -r kernel_peak < /sys/fs/cgroup/memory.peak
            fi
            ;;
        cgroup-v1-*)
            read -r container < /sys/fs/cgroup/memory/memory.usage_in_bytes
            while read -r metric value; do
                if [[ "$metric" == "total_inactive_file" ]]; then inactive_file=$value; break; fi
            done < /sys/fs/cgroup/memory/memory.stat
            if [[ -r /sys/fs/cgroup/memory/memory.max_usage_in_bytes ]]; then
                read -r kernel_peak < /sys/fs/cgroup/memory/memory.max_usage_in_bytes
            fi
            ;;
        *) container=$process_rss ;;
    esac

    working_set=$((container > inactive_file ? container - inactive_file : 0))
    if ((working_set > peak_working_set)); then peak_working_set=$working_set; fi
    if ((container > peak_container)); then peak_container=$container; fi
    if ((process_rss > peak_process_rss)); then peak_process_rss=$process_rss; fi
    if ((kernel_peak > peak_kernel_container)); then peak_kernel_container=$kernel_peak; fi
    sample_count=$((sample_count + 1))
    elapsed=$((SECONDS - start_seconds))
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    printf '%s,%s,%s,%s,%s,%s\n' "$timestamp" "$elapsed" "$container" "$working_set" "$process_rss" "$kernel_peak" >> "$csv_file"
    awk -v elapsed="$elapsed" -v working="$working_set" -v total="$container" -v rss="$process_rss" -v peak="$peak_working_set" \
        'BEGIN { printf "[memory %02d:%02d] working set %8.1f MiB | container total %8.1f MiB | process RSS %8.1f MiB | peak working set %8.1f MiB\n", int(elapsed/60), elapsed%60, working/1048576, total/1048576, rss/1048576, peak/1048576 }'
}

echo "Memory is always sampled every ${sample_seconds}s during restore, build and verification."
echo "Working set = cgroup total minus inactive file cache; process RSS may double-count shared pages."
echo "Metric source: $metric_source"
echo "CSV: $csv_file"
sample_memory

build_pid=''
stop_build() {
    if [[ -n "$build_pid" ]]; then
        kill -TERM "$build_pid" 2>/dev/null || true
    fi
}
trap stop_build INT TERM

pwsh -NoLogo -NoProfile -File /workspace/build.ps1 \
    -Configuration "$configuration" \
    -MaxCpuCount "$max_cpu_count" \
    -LogDirectory "$results_directory" &
build_pid=$!

while kill -0 "$build_pid" 2>/dev/null; do
    sleep "$sample_seconds"
    sample_memory
done

set +e
wait "$build_pid"
build_exit_code=$?
set -e
sample_memory
elapsed_seconds=$((SECONDS - start_seconds))

cat > "$summary_file" <<EOF
{
  "exitCode": $build_exit_code,
  "configuration": "$configuration",
  "maxCpuCount": $max_cpu_count,
  "sampleIntervalSeconds": $sample_seconds,
  "sampleCount": $sample_count,
  "elapsedSeconds": $elapsed_seconds,
  "workingSetMetric": "$metric_source",
  "peakSampledWorkingSetBytes": $peak_working_set,
  "peakSampledContainerBytes": $peak_container,
  "peakSampledProcessRssBytes": $peak_process_rss,
  "kernelPeakContainerBytes": $peak_kernel_container,
  "includes": "Whole container during restore, build and verification, including MSBuild workers and compilers.",
  "notes": "Working-set peaks are sampled and may miss short spikes. Container totals include file cache. Summed RSS may double-count shared pages. These are not retained managed-heap measurements."
}
EOF

awk -v code="$build_exit_code" -v elapsed="$elapsed_seconds" -v working="$peak_working_set" -v total="$peak_kernel_container" \
    'BEGIN { printf "Memory summary: exit %d, elapsed %ds, peak sampled working set %.1f MiB, kernel peak container total %.1f MiB\n", code, elapsed, working/1048576, total/1048576 }'
echo "Saved $csv_file and $summary_file"
exit "$build_exit_code"
