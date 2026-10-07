#!/usr/bin/env bash
# Switch the single Ollama installation to the NVIDIA CUDA backend.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$HERE/lib/common.sh"
source "$HERE/lib/switch.sh"
switch_backend nvidia "./use-nvidia.sh" "$@"
