#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v pwsh >/dev/null 2>&1; then
    echo 'Native builds need PowerShell 7 (pwsh). Alternatively use ./build-docker.sh, which needs only Docker.' >&2
    exit 1
fi
exec pwsh -NoLogo -NoProfile -File "$repo_root/build.ps1" "$@"
