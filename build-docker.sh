#!/usr/bin/env bash
set -euo pipefail

configuration=Release
max_cpu_count=2
sample_seconds=2
results_directory=''

usage() {
    echo "Usage: ./build-docker.sh [--configuration Debug|Release] [--max-cpu-count N] [--sample-seconds N] [--results-directory PATH]"
}

while (($#)); do
    case "$1" in
        --configuration|--max-cpu-count|--sample-seconds|--results-directory)
            if (($# < 2)); then usage >&2; exit 2; fi
            case "$1" in
                --configuration) configuration=$2 ;;
                --max-cpu-count) max_cpu_count=$2 ;;
                --sample-seconds) sample_seconds=$2 ;;
                --results-directory) results_directory=$2 ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ ! "$configuration" =~ ^(Debug|Release)$ || ! "$max_cpu_count" =~ ^[1-9][0-9]*$ || ! "$sample_seconds" =~ ^[1-9][0-9]*$ ]]; then
    usage >&2
    exit 2
fi
if ((max_cpu_count > 256 || sample_seconds > 3600)); then
    usage >&2
    exit 2
fi

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
image_name=pawel-msbuildcachetesting:local
command -v docker >/dev/null || { echo 'Docker is required.' >&2; exit 1; }
docker_os=$(docker info --format '{{.OSType}}')
if [[ "$docker_os" != linux ]]; then
    echo 'This build requires Docker configured for Linux containers.' >&2
    exit 1
fi

if [[ -z "$results_directory" ]]; then
    run_name="$(date -u '+%Y%m%d-%H%M%S')-$$"
    results_directory="$repository_root/artifacts/docker/$run_name"
elif [[ "$results_directory" != /* ]]; then
    results_directory="$repository_root/$results_directory"
fi
mkdir -p "$results_directory"
results_directory=$(cd -- "$results_directory" && pwd)

echo "Building Linux SDK image from $repository_root"
docker build --file "$repository_root/Dockerfile" --tag "$image_name" "$repository_root"
echo 'Running a fresh traversal build; memory sampling is always enabled.'
echo "Results: $results_directory"

set +e
docker run --rm \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$results_directory,target=/results" \
    --env "CONFIGURATION=$configuration" \
    --env "MAX_CPU_COUNT=$max_cpu_count" \
    --env "MEMORY_SAMPLE_SECONDS=$sample_seconds" \
    "$image_name" 2>&1 | tee "$results_directory/console.log"
build_exit_code=${PIPESTATUS[0]}
set -e
if ((build_exit_code)); then
    echo "Container build failed (exit $build_exit_code). Results: $results_directory" >&2
    exit "$build_exit_code"
fi
echo "Docker build and verification succeeded. Results: $results_directory"
