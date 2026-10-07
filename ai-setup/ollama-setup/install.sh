#!/usr/bin/env bash
# Install or update the single Ollama installation (all GPU backend bundles).
# The newest release is discovered from GitHub at run time; nothing is
# downloaded when the installed version is already current.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$HERE/lib/common.sh"

REPO="${OLLAMA_REPO:-ollama/ollama}"
GH_API="https://api.github.com/repos/$REPO"
GH_WEB="https://github.com/$REPO"

usage() {
  cat <<USAGE
Usage: ./install.sh [options]

Installs Ollama (or updates it only when a newer release exists) together with
the CUDA and ROCm backend bundles, so ./use-amd.sh and ./use-nvidia.sh can
switch GPUs without reinstalling. Also creates the 'ollama' user and systemd
service if missing. Idempotent.

Options:
  -c, --check          Only report installed vs latest version (exit 10 if an update exists)
  -f, --force          Reinstall even if already up to date
      --version VER    Install a specific release (e.g. 0.12.3) instead of the latest
      --no-start       Do not enable/start the service
  -h, --help           Show this help

Environment: OLLAMA_INSTALL_PREFIX (default /usr/local, used on first install)
USAGE
}

CHECK=0; FORCE=0; PIN=""; START=1
while (($#)); do
  case "$1" in
    -c|--check) CHECK=1 ;;
    -f|--force) FORCE=1 ;;
    --version) PIN="${2:?--version needs a value}"; shift ;;
    --no-start) START=0 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

((CHECK)) || { ensure_root "$@"; init_state; }
TMP_DIRS=()
cleanup() { local d; for d in "${TMP_DIRS[@]:-}"; do [[ -n $d ]] && rm -rf "$d"; done; }
trap cleanup EXIT

# ------------------------------------------------------------ preflight ----
hdr "Preflight"
[[ "$(uname -s)" == Linux ]] || die "This script supports Linux only."
ARCH="$(detect_arch)"
[[ $ARCH != unsupported ]] || die "Unsupported CPU architecture: $(uname -m) (need x86_64 or aarch64)."
need_cmd curl python3 tar sha256sum
command -v zstd >/dev/null 2>&1 || die "zstd is required to unpack Ollama releases (sudo apt install zstd)."
command -v systemctl >/dev/null 2>&1 || die "systemd (systemctl) is required."
info "OS:           $(detect_os)"
info "Architecture: $ARCH"

if [[ $ARCH == amd64 ]]; then
  has_amd_hw    && info "GPU:          AMD detected     -> ROCm backend will be installed"
  has_nvidia_hw && info "GPU:          NVIDIA detected  -> CUDA backend will be installed"
  has_amd_hw || has_nvidia_hw || warn "No AMD/NVIDIA GPU detected via lspci; installing all backends anyway."
else
  warn "ROCm bundles are published for amd64 only; installing the arm64 build (CUDA/CPU)."
fi

# Driver sanity (informational here; the use-*.sh scripts enforce it).
if has_amd_hw; then
  [[ -e /dev/kfd ]] && ok "AMD: amdgpu + /dev/kfd present" || warn "AMD GPU found but /dev/kfd is missing (amdgpu driver not ready) - ./use-amd.sh will refuse until fixed."
fi
if has_nvidia_hw; then
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    ok "NVIDIA: driver OK (CUDA $(nvidia_cuda_version))"
  else
    warn "NVIDIA GPU found but the driver is not working - ./use-nvidia.sh will refuse until fixed."
  fi
fi

# ------------------------------------------------- version discovery ----
hdr "Versions"
INSTALLED="$(ollama_installed_version)"
[[ -n $INSTALLED ]] && info "Installed: $INSTALLED" || info "Installed: none"

RELEASE_JSON="$(mktemp)"; TMP_DIRS+=("$RELEASE_JSON")
fetch_release() {
  local path="latest"; [[ -n $PIN ]] && path="tags/v${PIN#v}"
  curl -fsSL --retry 3 --retry-delay 2 -m 30 -H 'Accept: application/vnd.github+json' \
    "$GH_API/releases/$path" -o "$RELEASE_JSON"
}
json_tag() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$RELEASE_JSON"; }
# json_asset <regex>  -> "<name> <url>" of the first matching asset
json_asset() {
  python3 -I - "$RELEASE_JSON" "$1" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1]))
pat = re.compile(sys.argv[2])
for a in data.get("assets", []):
    if pat.search(a["name"]):
        print(a["name"], a["browser_download_url"]); break
PY
}

TAG=""; API_OK=1
if fetch_release 2>/dev/null; then
  TAG="$(json_tag)"
else
  API_OK=0
  warn "GitHub API unavailable (rate limit or network); falling back to the release redirect."
  if [[ -n $PIN ]]; then TAG="v${PIN#v}"
  else
    TAG="$(curl -fsSIL -m 30 -o /dev/null -w '%{url_effective}' "$GH_WEB/releases/latest" | sed 's|.*/tag/||')" || true
  fi
fi
[[ -n $TAG && $TAG != */* ]] || die "Could not determine the Ollama release to install (check your network connection)."
LATEST="${TAG#v}"
info "Target:    $LATEST${PIN:+ (pinned)}"

NEED_BACKEND_FIX=0
if [[ -n $INSTALLED && $ARCH == amd64 ]] && ! has_rocm_libs; then NEED_BACKEND_FIX=1; fi

if [[ -n $INSTALLED ]] && version_ge "$INSTALLED" "$LATEST" && ((!FORCE)) && ((!NEED_BACKEND_FIX)) && [[ -z $PIN || $INSTALLED == "$LATEST" ]]; then
  ok "Ollama $INSTALLED is up to date; no download needed."
  UP_TO_DATE=1
else
  UP_TO_DATE=0
  if ((CHECK)); then
    warn "Update available: $INSTALLED -> $LATEST   (run ./install.sh)"
    exit 10
  fi
  ((NEED_BACKEND_FIX)) && info "ROCm backend bundle missing from the current install; reinstalling to add it."
fi
((CHECK)) && exit 0

# ------------------------------------------------------------- service ----
ensure_service_user() {
  if ! id "$SERVICE_NAME" >/dev/null 2>&1; then
    info "Creating system user '$SERVICE_NAME'"
    useradd -r -s /bin/false -U -m -d /usr/share/ollama "$SERVICE_NAME"
  fi
  local g
  for g in render video; do getent group "$g" >/dev/null && usermod -aG "$g" "$SERVICE_NAME"; done
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then usermod -aG "$SERVICE_NAME" "$SUDO_USER" || true; fi
}

ensure_unit() {
  local bin; bin="$(readlink -f "$(ollama_bin)")"
  if [[ -f $UNIT_FILE ]]; then
    grep -q "ExecStart=$bin serve" "$UNIT_FILE" || warn "$UNIT_FILE ExecStart differs from $bin; leaving it unchanged."
    return
  fi
  info "Creating $UNIT_FILE"
  write_if_changed "$UNIT_FILE" <<UNIT || true
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=$bin serve
User=$SERVICE_NAME
Group=$SERVICE_NAME
Restart=always
RestartSec=3
Environment="PATH=$PATH"

[Install]
WantedBy=default.target
UNIT
}

finish_service() {
  ensure_service_user
  ensure_unit
  systemctl daemon-reload
  if ((START)); then
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || warn "Could not enable the service at boot."
    if service_active && ((UP_TO_DATE)); then
      ok "Service already running"
    else
      restart_service || return 1
      ok "Service running"
    fi
  fi
}

models_notice() {
  hdr "Model storage"
  local eff d other=0
  eff="$(effective_models_dir)"
  info "The service stores models in: $eff ($(models_count "$eff" 2>/dev/null || echo 0) models)"
  while read -r d; do
    [[ $d == "$eff" || ! -d $d ]] && continue
    models_has "$d" && { warn "Existing models found elsewhere: $d ($(models_size "$d"))"; other=1; }
  done < <(candidate_models_dirs)
  ((other)) && warn "The service will not see those. See: ./ollama-models.sh set <path> --migrate"
  return 0
}

next_steps() {
  hdr "Next steps"
  local b; b="$(current_backend)"
  if [[ $b == none ]]; then
    has_amd_hw    && echo "  ./use-amd.sh      # run Ollama on the AMD GPU (ROCm)"
    has_nvidia_hw && echo "  ./use-nvidia.sh   # run Ollama on the NVIDIA GPU (CUDA)"
  else
    echo "  Active backend: $b"
  fi
  echo "  ./ollama-status.sh"
}

if ((UP_TO_DATE)); then
  finish_service || die "Service failed to start. Inspect: journalctl -u $SERVICE_NAME -n 50"
  models_notice; next_steps
  exit 0
fi

# ------------------------------------------------------------ download ----
hdr "Downloading Ollama $LATEST"
case "$ARCH" in amd64) ARCHES=(amd64 amd64-rocm) ;; arm64) ARCHES=(arm64) ;; esac
DL="$(mktemp -d "$STATE_DIR/download.XXXXXX")"; TMP_DIRS+=("$DL")

resolve_asset() { # <suffix e.g. amd64-rocm> -> "name url"
  local sfx="$1" res=""
  if ((API_OK)); then res="$(json_asset "^ollama-linux-${sfx}\.(tar\.zst|tgz)\$")"; fi
  if [[ -z $res ]]; then
    local ext
    for ext in tar.zst tgz; do
      if curl -fsIL -m 20 -o /dev/null "$GH_WEB/releases/download/$TAG/ollama-linux-$sfx.$ext"; then
        res="ollama-linux-$sfx.$ext $GH_WEB/releases/download/$TAG/ollama-linux-$sfx.$ext"; break
      fi
    done
  fi
  echo "$res"
}

SUMS=""
if ((API_OK)); then
  sums_url="$(json_asset '^sha256sum\.txt$' | awk '{print $2}')"
  [[ -n $sums_url ]] && SUMS="$(curl -fsSL --retry 3 -m 60 "$sums_url" 2>/dev/null || true)"
fi
[[ -n $SUMS ]] || warn "No sha256sum.txt published for this release; integrity check will be skipped."

ARCHIVES=()
for sfx in "${ARCHES[@]}"; do
  read -r name url <<<"$(resolve_asset "$sfx")"
  if [[ -z ${name:-} ]]; then
    [[ $sfx == *rocm ]] && { warn "No ROCm bundle in release $TAG; AMD switching will be unavailable."; continue; }
    die "No Linux '$sfx' asset found in release $TAG."
  fi
  info "Fetching $name"
  curl -fL --retry 3 --retry-delay 3 -C - --progress-bar -o "$DL/$name" "$url" ||
    die "Download failed: $url"
  if [[ -n $SUMS ]]; then
    want="$(awk -v n="$name" '{f=$2; sub(/^\*/,"",f); sub(/^\.\//,"",f)} f==n {print $1}' <<<"$SUMS" | head -1)"
    if [[ -n $want ]]; then
      got="$(sha256sum "$DL/$name" | cut -d' ' -f1)"
      [[ $got == "$want" ]] || die "Checksum mismatch for $name (expected $want, got $got). Aborting; nothing was installed."
      ok "Checksum verified: $name"
    else
      warn "No checksum listed for $name"
    fi
  fi
  ARCHIVES+=("$DL/$name")
done
((${#ARCHIVES[@]})) || die "Nothing was downloaded."

# -------------------------------------------------------------- extract ----
hdr "Installing"
STAGE="$DL/stage"; mkdir -p "$STAGE"
for a in "${ARCHIVES[@]}"; do
  info "Unpacking $(basename "$a")"
  case "$a" in
    *.tar.zst) zstd -dc "$a" | tar -xf - -C "$STAGE" || die "Failed to unpack $a" ;;
    *.tgz)     tar -xzf "$a" -C "$STAGE" || die "Failed to unpack $a" ;;
  esac
done
[[ -x $STAGE/bin/ollama && -d $STAGE/lib/ollama ]] || die "Unexpected archive layout (bin/ollama or lib/ollama missing); nothing was installed."

PREFIX="$(ollama_prefix)"
BIN_DIR="$PREFIX/bin"; LIB_DST="$PREFIX/lib/ollama"
mkdir -p "$BIN_DIR" "$PREFIX/lib"
OLD="$STATE_DIR/previous-install"
rm -rf "$OLD"; mkdir -p "$OLD"

WAS_ACTIVE=0; service_active && WAS_ACTIVE=1
((WAS_ACTIVE)) && { info "Stopping $SERVICE_NAME for the swap"; systemctl stop "$SERVICE_NAME"; }

[[ -e $BIN_DIR/ollama ]] && mv "$BIN_DIR/ollama" "$OLD/ollama"
[[ -d $LIB_DST ]] && mv "$LIB_DST" "$OLD/lib-ollama"

restore_old_install() {
  warn "Restoring the previous Ollama installation..."
  rm -rf "$BIN_DIR/ollama" "$LIB_DST"
  [[ -e $OLD/ollama ]] && mv "$OLD/ollama" "$BIN_DIR/ollama"
  [[ -d $OLD/lib-ollama ]] && mv "$OLD/lib-ollama" "$LIB_DST"
  ((WAS_ACTIVE)) && { systemctl start "$SERVICE_NAME" || true; }
}

if ! { mv "$STAGE/bin/ollama" "$BIN_DIR/ollama" && mv "$STAGE/lib/ollama" "$LIB_DST"; }; then
  restore_old_install
  die "Failed to place new files; previous installation restored."
fi
chmod 0755 "$BIN_DIR/ollama"
[[ $BIN_DIR == /usr/local/bin || $BIN_DIR == /usr/bin ]] || ln -sf "$BIN_DIR/ollama" /usr/local/bin/ollama 2>/dev/null || true
ok "Installed to $BIN_DIR/ollama and $LIB_DST ($(installed_backends))"

NEW_VER="$(ollama_installed_version)"
[[ $NEW_VER == "$LATEST" ]] || warn "Installed binary reports '$NEW_VER' (expected $LATEST)."

if ! finish_service; then
  err "Service did not come up with the new version."
  if [[ -d $OLD/lib-ollama || -e $OLD/ollama ]]; then
    restore_old_install
    restart_service || true
    die "Update failed and the previous version was restored. Inspect: journalctl -u $SERVICE_NAME -n 50"
  fi
  die "Service failed to start. Inspect: journalctl -u $SERVICE_NAME -n 50"
fi
rm -rf "$OLD"
ok "Ollama ${NEW_VER:-$LATEST} is installed${INSTALLED:+ (was $INSTALLED)}"
models_notice
next_steps
