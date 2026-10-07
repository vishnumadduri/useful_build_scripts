#!/usr/bin/env bash
# Report Ollama version, active GPU backend, GPUs, driver versions, service
# state and whether GPU acceleration is actually working. Needs no root.
# Exit code: 0 = GPU acceleration working, 1 = not working, 3 = Ollama not installed.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$HERE/lib/common.sh"

case "${1:-}" in
  -h|--help)
    cat <<USAGE
Usage: ./ollama-status.sh

Shows Ollama version, active GPU backend, detected GPUs, ROCm/CUDA versions,
service status, model storage and whether GPU acceleration is working.
Exit status is 0 when the GPU is in use, non-zero otherwise.
USAGE
    exit 0 ;;
esac

row() { printf '  %-22s %s\n' "$1" "$2"; }
good() { printf '%s%s%s' "$C_GRN" "$*" "$C_RST"; }
bad()  { printf '%s%s%s' "$C_RED" "$*" "$C_RST"; }
meh()  { printf '%s%s%s' "$C_YEL" "$*" "$C_RST"; }

bin="$(ollama_bin)"
if [[ -z $bin ]]; then
  err "Ollama is not installed. Run ./install.sh"
  exit 3
fi

backend="$(current_backend)"
version="$(ollama_installed_version)"

hdr "Ollama"
row "Version"         "${version:-unknown}  ($bin)"
row "Installed libs"  "$(installed_backends)"
case "$backend" in
  amd)    row "Active backend" "$(good 'AMD ROCm')   (config: $GPU_DROPIN)" ;;
  nvidia) row "Active backend" "$(good 'NVIDIA CUDA')   (config: $GPU_DROPIN)" ;;
  *)      row "Active backend" "$(meh 'not configured')  (Ollama auto-detects; run ./use-amd.sh or ./use-nvidia.sh)" ;;
esac

hdr "System"
row "OS"           "$(detect_os)"
row "Architecture" "$(detect_arch)"

hdr "GPUs"
pci="$(gpu_pci_lines)"
if [[ -n $pci ]]; then
  while IFS= read -r l; do row "PCI" "$l"; done <<<"$pci"
else
  row "PCI" "none found (is pciutils installed?)"
fi

amd_list="$(amd_gpu_list)"
if [[ -n $amd_list ]]; then
  while read -r idx gfx; do
    supported="$([[ " $ROCM_GFX_SUPPORTED " == *" $gfx "* ]] && good supported || bad 'unsupported by Ollama ROCm')"
    row "AMD GPU #$idx" "$gfx  ($supported)"
  done <<<"$amd_list"
  row "amdgpu / /dev/kfd" "$([[ -d /sys/module/amdgpu ]] && good loaded || bad missing) / $([[ -e /dev/kfd ]] && good present || bad missing)"
  rocm_sys=""
  [[ -r /opt/rocm/.info/version ]] && rocm_sys="$(cat /opt/rocm/.info/version)"
  hip="$(installed_backends | tr ' ' '\n' | grep '^rocm' | tr '\n' ' ')"
  row "ROCm (system)"  "${rocm_sys:-not installed (not required; Ollama bundles its own)}"
  row "ROCm (bundled)" "${hip:-not installed}"
elif has_amd_hw; then
  row "AMD GPU" "$(bad 'present on PCI but no ROCm/KFD device (amdgpu driver or /dev/kfd missing)')"
fi

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  while IFS= read -r l; do row "NVIDIA GPU" "$l  (index, name, driver, compute cap)"; done < <(nvidia_gpu_list)
  row "CUDA (driver max)" "$(nvidia_cuda_version)"
  cuda_bundled="$(installed_backends | tr ' ' '\n' | grep '^cuda' | tr '\n' ' ')"
  row "CUDA (bundled)" "${cuda_bundled:-not installed}"
elif has_nvidia_hw; then
  row "NVIDIA GPU" "$(bad 'present on PCI but nvidia-smi/driver not working')"
fi

hdr "Service"
if service_exists; then
  state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
  [[ $state == active ]] && row "Status" "$(good active) (enabled: ${enabled:-?})" || row "Status" "$(bad "${state:-unknown}") (enabled: ${enabled:-?})"
  row "API ($OLLAMA_API)" "$(api_ready && good reachable || bad unreachable)"
else
  state="missing"
  row "Status" "$(bad 'systemd unit not found')"
fi

hdr "Models"
mdir="$(effective_models_dir)"
if [[ -d $mdir ]]; then
  row "Directory" "$mdir"
  row "Models / size" "$(models_count "$mdir") / $(models_size "$mdir")"
else
  row "Directory" "$mdir  $(meh '(does not exist yet)')"
fi
row "Details" "./ollama-models.sh"

hdr "GPU acceleration"
working=0
reason=""
if [[ ${state:-} != active ]]; then
  reason="service is not running"
else
  start="$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp --value 2>/dev/null | sed 's/^[A-Za-z]* //')"
  libs="$(gpu_libs_since "${start:-1 hour ago}" || true)"
  if [[ -z $libs ]]; then
    reason="no device discovery in the journal (not readable, or an older Ollama that discovers on first model load)"
  elif grep -qixE 'rocm|cuda' <<<"$libs"; then
    working=1
    row "Libraries in use" "$(good "$(tr '\n' ' ' <<<"$libs")")"
    case "$backend:$libs" in
      amd:*CUDA*|nvidia:*ROCm*) row "Note" "$(meh "backend '$backend' is configured but the other vendor's library is also active")" ;;
    esac
  else
    reason="Ollama reported only: $(tr '\n' ' ' <<<"$libs")(CPU)"
  fi

  ps_out="$(curl -fsS -m 3 "$OLLAMA_API/api/ps" 2>/dev/null || true)"
  if [[ -n $ps_out ]] && grep -q '"name"' <<<"$ps_out"; then
    echo "  Loaded models:"
    "$bin" ps 2>/dev/null | sed 's/^/    /' || true
  else
    row "Loaded models" "none (load one with 'ollama run <model>' to see the GPU/CPU split)"
  fi
fi

echo
if ((working)); then
  echo "  Result: $(good 'GPU acceleration is working')"
  exit 0
else
  echo "  Result: $(bad 'GPU acceleration NOT confirmed') - $reason"
  echo "  Hint: ./use-amd.sh or ./use-nvidia.sh, then 'journalctl -u $SERVICE_NAME -n 50'"
  exit 1
fi
