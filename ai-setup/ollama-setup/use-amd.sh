#!/usr/bin/env bash
# Switch the single Ollama installation to the AMD ROCm (Radeon AI PRO R9700) backend.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$HERE/lib/common.sh"
source "$HERE/lib/switch.sh"
switch_backend amd "./use-amd.sh" "$@"
