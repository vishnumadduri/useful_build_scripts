#!/usr/bin/env bash
# Shared helpers for the ollama-setup scripts. Source this file; do not execute it.
#
# Design: ONE Ollama installation (binary + every backend library bundle under
# <prefix>/lib/ollama). The active GPU backend is chosen purely by a systemd
# drop-in that sets GPU visibility variables, so switching never reinstalls.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(dirname "$LIB_DIR")"
STATE_DIR="${OLLAMA_SETUP_STATE_DIR:-$SETUP_DIR/.state}"
BACKUP_DIR="$STATE_DIR/backups"
CONFIG_DIR="$SETUP_DIR/config"

SERVICE_NAME="ollama"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
GPU_DROPIN="$DROPIN_DIR/10-ollama-setup-gpu.conf"
MODELS_DROPIN="$DROPIN_DIR/20-ollama-setup-models.conf"
CONTEXT_DROPIN="$DROPIN_DIR/30-ollama-setup-context.conf"

OLLAMA_API="${OLLAMA_API_URL:-http://127.0.0.1:11434}"
READY_TIMEOUT="${OLLAMA_READY_TIMEOUT:-90}"
KEEP_BACKUPS=10

# ROCm gfx targets Ollama's bundled ROCm build can drive. The Radeon AI PRO
# R9700 (RDNA4 / Navi 48) is gfx1201. Override via the environment if needed.
ROCM_GFX_SUPPORTED="${OLLAMA_ROCM_GFX_SUPPORTED:-gfx900 gfx906 gfx908 gfx90a gfx942 gfx1030 gfx1100 gfx1101 gfx1102 gfx1150 gfx1151 gfx1200 gfx1201}"
NVIDIA_MIN_COMPUTE="5.0"

# ---------------------------------------------------------------- output ----
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

info() { printf '%s[INFO]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_RST"; }

# ------------------------------------------------------------ privileges ----
# Usage: ensure_root "$@"   (re-executes the calling script under sudo)
ensure_root() {
  [[ $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || die "Root privileges are required and sudo was not found."
  info "Root privileges required; re-running with sudo..."
  exec sudo -- "$0" "$@"
}

# Create the state dir and take an exclusive lock so two runs cannot overlap.
init_state() {
  mkdir -p "$BACKUP_DIR"
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    chown -R "$SUDO_USER": "$STATE_DIR" 2>/dev/null || true
  fi
  exec 9>"$STATE_DIR/.lock"
  flock -n 9 || die "Another ollama-setup operation is already running."
}

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

# ------------------------------------------------------------- detection ----
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "unsupported" ;;
  esac
}

detect_os() {
  local name="unknown"
  if [[ -r /etc/os-release ]]; then
    name="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
  fi
  echo "$(uname -s) / $name / kernel $(uname -r)"
}

gpu_pci_lines() {
  command -v lspci >/dev/null 2>&1 || return 0
  lspci -nn 2>/dev/null | grep -E 'VGA compatible|3D controller|Display controller' || true
}
has_nvidia_hw() { gpu_pci_lines | grep -qE '\[10de:'; }
has_amd_hw()    { gpu_pci_lines | grep -qE '\[1002:'; }

# AMD compute GPUs as seen by the kernel's KFD interface (no ROCm install
# needed). Prints "<index> <gfxid>" per GPU; index matches ROCR_VISIBLE_DEVICES.
amd_gpu_list() {
  local base=/sys/class/kfd/kfd/topology/nodes node simd v idx=0
  [[ -d $base ]] || return 0
  while read -r node; do
    [[ -r $node/properties ]] || continue
    simd="$(awk '$1=="simd_count"{print $2}' "$node/properties")"
    [[ ${simd:-0} -gt 0 ]] || continue
    v="$(awk '$1=="gfx_target_version"{print $2}' "$node/properties")"
    [[ ${v:-0} -gt 0 ]] || continue
    printf '%d gfx%d%d%x\n' "$idx" $((v / 10000)) $(((v / 100) % 100)) $((v % 100))
    idx=$((idx + 1))
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d | sort -V)
}

nvidia_gpu_list() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi --query-gpu=index,name,driver_version,compute_cap --format=csv,noheader 2>/dev/null ||
    nvidia-smi --query-gpu=index,name,driver_version --format=csv,noheader 2>/dev/null || true
}

nvidia_cuda_version() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: *\([0-9.]*\).*/\1/p' | head -1
}

# version_ge A B -> true when A >= B (dotted versions, optional leading v)
version_ge() {
  local a="${1#v}" b="${2#v}"
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" == "$b" ]]
}

# --------------------------------------------------------- ollama install ----
ollama_bin() { command -v ollama 2>/dev/null || true; }

ollama_prefix() {
  local bin
  bin="$(ollama_bin)"
  if [[ -n $bin ]]; then
    dirname "$(dirname "$(readlink -f "$bin")")"
  else
    echo "${OLLAMA_INSTALL_PREFIX:-/usr/local}"
  fi
}

ollama_lib_dir() { echo "$(ollama_prefix)/lib/ollama"; }

ollama_installed_version() {
  local bin out
  bin="$(ollama_bin)"
  [[ -n $bin ]] || return 0
  out="$("$bin" --version 2>/dev/null || true)"
  # With the server down only "Warning: client version is X" is printed.
  { grep -oE '(ollama|client) version is [^[:space:]]+' <<<"$out" || true; } | head -1 | awk '{print $4}'
}

# Backend library bundles present in the single installation. Directory names
# are versioned (cuda_v12, cuda_v13, rocm_v7_2, ...) so match by prefix.
installed_backends() {
  local lib d out=()
  lib="$(ollama_lib_dir)"
  for d in "$lib"/cuda_v* "$lib"/rocm* "$lib"/vulkan; do [[ -d $d ]] && out+=("$(basename "$d")"); done
  echo "${out[*]:-}"
}
has_cuda_libs() { compgen -G "$(ollama_lib_dir)/cuda_v*" >/dev/null; }
has_rocm_libs() { compgen -G "$(ollama_lib_dir)/rocm*" >/dev/null; }

# ----------------------------------------------------------- service ops ----
service_user_home() { getent passwd "$SERVICE_NAME" | cut -d: -f6; }

service_exists() { systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; }
service_active() { systemctl is-active --quiet "$SERVICE_NAME"; }

api_ready() { curl -fsS -m 2 "$OLLAMA_API/api/version" >/dev/null 2>&1; }

wait_ready() {
  local i
  for ((i = 0; i < READY_TIMEOUT; i++)); do
    api_ready && return 0
    if systemctl is-failed --quiet "$SERVICE_NAME"; then return 1; fi
    sleep 1
  done
  return 1
}

restart_service() {
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
  systemctl restart "$SERVICE_NAME" && wait_ready
}

# Make sure the service account can reach GPU device nodes (idempotent).
ensure_service_groups() {
  id "$SERVICE_NAME" >/dev/null 2>&1 || return 0
  local g
  for g in render video; do
    if getent group "$g" >/dev/null && ! id -nG "$SERVICE_NAME" | tr ' ' '\n' | grep -qx "$g"; then
      info "Adding service user '$SERVICE_NAME' to group '$g'"
      usermod -aG "$g" "$SERVICE_NAME"
    fi
  done
}

# Atomically write stdin to $1 only if the content changed. Returns 0 if
# the file changed, 1 if it was already identical.
write_if_changed() {
  local dest="$1" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "$(dirname "$dest")/.tmp.XXXXXX")"
  cat >"$tmp"
  if [[ -f $dest ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0644 "$tmp"
  mv -f "$tmp" "$dest"
  return 0
}

# ------------------------------------------------------- GPU config state ----
# The active backend is recorded in a marker comment inside the drop-in.
current_backend() {
  local b=""
  if [[ -f $GPU_DROPIN ]]; then
    b="$(sed -n 's/^# ollama-setup backend=\(.*\)$/\1/p' "$GPU_DROPIN" | head -1)"
  fi
  echo "${b:-none}"
}

# Emit Environment= lines from an optional user override file (KEY=VALUE).
user_env_lines() {
  local f="$CONFIG_DIR/$1.env" line
  [[ -r $f ]] || return 0
  while IFS= read -r line; do
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || continue
    printf 'Environment="%s"\n' "${line//\"/\\\"}"
  done <"$f"
}

# render_gpu_dropin <amd|nvidia> <device-ids or empty>
render_gpu_dropin() {
  local backend="$1" ids="${2:-}"
  printf '# ollama-setup backend=%s\n' "$backend"
  printf '# Managed by ollama-setup (use-amd.sh / use-nvidia.sh). Manual edits are overwritten.\n'
  printf '[Service]\n'
  printf 'Environment="OLLAMA_SETUP_BACKEND=%s"\n' "$backend"
  # Native backends only (ROCm / CUDA); never fall back to the Vulkan backend.
  printf 'Environment="OLLAMA_VULKAN=0"\n'
  case "$backend" in
    amd)
      # Hide NVIDIA devices; expose only the supported AMD GPU(s).
      printf 'Environment="CUDA_VISIBLE_DEVICES=-1"\n'
      [[ -n $ids ]] && printf 'Environment="ROCR_VISIBLE_DEVICES=%s"\n' "$ids"
      ;;
    nvidia)
      # Hide AMD devices; expose NVIDIA (all, or the requested ids).
      printf 'Environment="HIP_VISIBLE_DEVICES=-1"\n'
      printf 'Environment="ROCR_VISIBLE_DEVICES=-1"\n'
      [[ -n $ids ]] && printf 'Environment="CUDA_VISIBLE_DEVICES=%s"\n' "$ids"
      ;;
  esac
  user_env_lines "$backend"
}

# ----------------------------------------------------- backup / rollback ----
# Snapshot the current GPU drop-in. Prints the backup id.
snapshot_config() {
  local id dir
  id="$(date +%Y%m%d-%H%M%S)-$(current_backend)"
  dir="$BACKUP_DIR/$id"
  mkdir -p "$dir"
  rm -f "$dir/gpu.conf" "$dir/gpu.absent"
  if [[ -f $GPU_DROPIN ]]; then
    cp -p "$GPU_DROPIN" "$dir/gpu.conf"
  else
    : >"$dir/gpu.absent"
  fi
  echo "$id" >"$STATE_DIR/last-backup"
  # prune old snapshots
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((KEEP_BACKUPS + 1)) |
    while read -r old; do rm -rf "$old"; done
  echo "$id"
}

list_snapshots() { find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r; }

restore_snapshot() {
  local dir="$BACKUP_DIR/$1"
  [[ -d $dir ]] || return 1
  if [[ -f $dir/gpu.conf ]]; then
    mkdir -p "$DROPIN_DIR"
    cp -p "$dir/gpu.conf" "$GPU_DROPIN"
  else
    rm -f "$GPU_DROPIN"
  fi
}

# --------------------------------------------------------- GPU validation ----
# Both validators set VALID_IDS (device ids to expose) and return non-zero with
# an actionable message on failure. FORCE=1 downgrades "unsupported" to a warning.
validate_amd() {
  VALID_IDS=""
  has_amd_hw || { err "No AMD GPU found on the PCI bus."; return 1; }

  if [[ ! -d /sys/module/amdgpu ]]; then
    err "The 'amdgpu' kernel driver is not loaded."
    echo "      Install/enable the amdgpu driver (AMD ROCm 'amdgpu-dkms' or a recent kernel with RDNA4 support) and reboot." >&2
    return 1
  fi
  if [[ ! -e /dev/kfd ]]; then
    err "/dev/kfd is missing: the ROCm compute interface is unavailable."
    echo "      Check 'dmesg | grep -i amdgpu' and that your kernel/firmware support the R9700 (RDNA4)." >&2
    return 1
  fi
  if ! has_rocm_libs; then
    err "Ollama's ROCm backend is not installed under $(ollama_lib_dir)."
    echo "      Run: ./install.sh --force   (installs the ROCm bundle alongside CUDA)" >&2
    return 1
  fi

  local list idx gfx ids=() found_supported=0
  list="$(amd_gpu_list)"
  if [[ -z $list ]]; then
    err "KFD reports no AMD compute GPUs."
    return 1
  fi
  while read -r idx gfx; do
    if [[ " $ROCM_GFX_SUPPORTED " == *" $gfx "* ]]; then
      ids+=("$idx"); found_supported=1
    else
      warn "AMD GPU #$idx ($gfx) is not in Ollama's supported ROCm list; it will be hidden."
    fi
  done <<<"$list"

  if ((!found_supported)); then
    if [[ ${FORCE:-0} == 1 ]]; then
      warn "No supported AMD GPU found; continuing because --force was given."
    else
      err "No supported AMD GPU found (detected: $(tr '\n' ' ' <<<"$list"))."
      echo "      Supported gfx targets: $ROCM_GFX_SUPPORTED" >&2
      echo "      Use --force, or set HSA_OVERRIDE_GFX_VERSION in config/amd.env, to try anyway." >&2
      return 1
    fi
  else
    VALID_IDS="$(IFS=,; echo "${ids[*]}")"
  fi
  ensure_service_groups
  return 0
}

validate_nvidia() {
  VALID_IDS=""
  has_nvidia_hw || { err "No NVIDIA GPU found on the PCI bus."; return 1; }

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    err "nvidia-smi not found: the NVIDIA driver is not installed."
    echo "      Install it (e.g. 'sudo ubuntu-drivers install' or your distro's nvidia-driver package) and reboot." >&2
    return 1
  fi
  if ! nvidia-smi -L >/dev/null 2>&1; then
    err "nvidia-smi cannot talk to the driver (module not loaded, or driver/library mismatch)."
    echo "      Try 'sudo modprobe nvidia' or reboot after a driver update." >&2
    return 1
  fi
  if ! has_cuda_libs; then
    err "Ollama's CUDA backend is not installed under $(ollama_lib_dir)."
    echo "      Run: ./install.sh --force" >&2
    return 1
  fi

  local cuda line cc ok_any=0
  cuda="$(nvidia_cuda_version)"
  if [[ -n $cuda ]] && ! version_ge "$cuda" "12.0"; then
    if [[ ${FORCE:-0} == 1 ]]; then
      warn "Driver supports only CUDA $cuda (< 12.0); continuing because of --force."
    else
      err "NVIDIA driver supports CUDA $cuda; Ollama's CUDA backend needs 12.0+. Update the driver."
      return 1
    fi
  fi
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    cc="$(awk -F', *' '{print $4}' <<<"$line")"
    if [[ -z $cc || $cc == "[N/A]" ]] || version_ge "$cc" "$NVIDIA_MIN_COMPUTE"; then
      ok_any=1
    else
      warn "NVIDIA GPU '$(awk -F', *' '{print $2}' <<<"$line")' has compute capability $cc (< $NVIDIA_MIN_COMPUTE); unsupported."
    fi
  done < <(nvidia_gpu_list)
  if ((!ok_any)) && [[ ${FORCE:-0} != 1 ]]; then
    err "No NVIDIA GPU with compute capability >= $NVIDIA_MIN_COMPUTE found."
    return 1
  fi
  VALID_IDS="${NVIDIA_GPU_IDS:-}"
  return 0
}

# ----------------------------------------------------- GPU verification ----
# Libraries Ollama reported for inference since a timestamp (ROCm, CUDA, cpu...).
gpu_libs_since() {
  journalctl -u "$SERVICE_NAME" --since "$1" --no-pager -o cat 2>/dev/null |
    grep 'msg="inference compute"' | grep -oE 'library=[A-Za-z0-9_]+' | cut -d= -f2 | sort -u
}

# verify_gpu <amd|nvidia> <since> [timeout]
# 0 = target GPU library confirmed, 1 = wrong backend / CPU only, 2 = could not verify
verify_gpu() {
  local want="$1" since="$2" deadline=$((SECONDS + ${3:-20})) libs="" want_lib
  [[ $want == amd ]] && want_lib="ROCm" || want_lib="CUDA"
  while ((SECONDS < deadline)); do
    libs="$(gpu_libs_since "$since")"
    [[ -n $libs ]] && break
    sleep 2
  done
  [[ -n $libs ]] || return 2
  grep -qix "$want_lib" <<<"$libs" && return 0
  VERIFY_FOUND="$(tr '\n' ' ' <<<"$libs")"
  return 1
}

# ------------------------------------------------------------ models dir ----
effective_models_dir() {
  local env v home
  env="$(systemctl show "$SERVICE_NAME" -p Environment --value 2>/dev/null || true)"
  v="$(grep -oE 'OLLAMA_MODELS=[^ ]+' <<<"$env" | head -1 | cut -d= -f2- | tr -d '"')"
  if [[ -n $v ]]; then echo "$v"; return; fi
  home="$(service_user_home)"
  echo "${home:-/usr/share/ollama}/.ollama/models"
}

# Every place Ollama models might already live on this machine.
candidate_models_dirs() {
  {
    effective_models_dir
    [[ -n ${OLLAMA_MODELS:-} ]] && echo "$OLLAMA_MODELS"
    echo "/usr/share/ollama/.ollama/models"
    echo "/var/lib/ollama/models"
    echo "/root/.ollama/models"
    find /home -maxdepth 3 -type d -path '*/.ollama/models' 2>/dev/null
  } | awk 'NF && !seen[$0]++'
}

# Model dirs under the service user's home are often unreadable by regular
# users (mode 750); fall back to passwordless sudo, else report "?".
_ro() {
  if [[ -r $1 && -x $1 ]] || [[ $EUID -eq 0 ]]; then "${@:2}"
  elif sudo -n true 2>/dev/null; then sudo -n "${@:2}"
  else return 1; fi
}
models_count() { local o; o="$(_ro "$1" find "$1/manifests" -type f 2>/dev/null)" || { echo "?"; return; }; [[ -n $o ]] && wc -l <<<"$o" || echo 0; }
models_size()  { local o; o="$(_ro "$1" du -sh "$1" 2>/dev/null)" || { echo "?"; return; }; cut -f1 <<<"$o"; }
models_has()   { local n; n="$(models_count "$1")"; [[ $n == "?" || ${n:-0} -gt 0 ]]; }
