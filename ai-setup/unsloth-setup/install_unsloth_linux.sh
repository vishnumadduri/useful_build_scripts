#!/usr/bin/env bash
# Installs Unsloth Studio on Ubuntu/Linux (counterpart of install_unsloth_windows_amd.ps1).
#
# A small wrapper around Unsloth's official installer. UNSLOTH_STUDIO_HOME is set
# only for the installer process, so Unsloth and its virtual environment are
# created under --install-dir. The official installer detects NVIDIA/AMD GPUs
# and picks matching PyTorch wheels (CPU fallback otherwise).
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install_unsloth_linux.sh [options]

  --action install|update   Install (default) or update Unsloth Studio
  --install-dir DIR         Install location (default: $HOME/UnslothStudio)
  --model-cache-dir DIR     Hugging Face cache root (default: <install-dir>/huggingface)
  --skip-autostart          Do not start Unsloth Studio after installation
  -h, --help                Show this help
USAGE
}

action="install"
install_dir="$HOME/UnslothStudio"
model_cache_dir=""
skip_autostart=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) action="${2:?--action needs a value}"; shift 2 ;;
    --install-dir) install_dir="${2:?--install-dir needs a value}"; shift 2 ;;
    --model-cache-dir) model_cache_dir="${2:?--model-cache-dir needs a value}"; shift 2 ;;
    --skip-autostart) skip_autostart=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$action" in
  install|update) ;;
  *) echo "--action must be 'install' or 'update'." >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This installer is for Linux. Use install_unsloth_windows_amd.ps1 on Windows." >&2
  exit 1
fi

if [[ "$EUID" -eq 0 ]]; then
  echo "Do not run as root; the installer uses sudo itself when needed." >&2
  exit 1
fi

expand_path() {
  local p="${1/#\~/$HOME}"
  mkdir -p "$p"
  (cd "$p" && pwd)
}

install_dir="$(expand_path "$install_dir")"
model_cache_dir="$(expand_path "${model_cache_dir:-$install_dir/huggingface}")"
hub_cache_dir="$(expand_path "$model_cache_dir/hub")"

write_launcher() {
  local launcher="$install_dir/start.sh"
  cat > "$launcher" <<LAUNCHER
#!/usr/bin/env bash
export UNSLOTH_STUDIO_HOME="$install_dir"
export HF_HOME="$model_cache_dir"
export HF_HUB_CACHE="$hub_cache_dir"
exec "\$(dirname "\$(readlink -f "\$0")")/bin/unsloth" studio -p 8888 "\$@"
LAUNCHER
  chmod +x "$launcher"
  echo "Created launcher: $launcher"
}

export UNSLOTH_STUDIO_HOME="$install_dir"
export HF_HOME="$model_cache_dir"
export HF_HUB_CACHE="$hub_cache_dir"
if "$skip_autostart"; then
  export UNSLOTH_SKIP_AUTOSTART=1
fi

if [[ "$action" == "update" ]]; then
  unsloth_bin="$install_dir/bin/unsloth"
  if [[ ! -x "$unsloth_bin" ]]; then
    echo "No Unsloth installation found at '$unsloth_bin'. Run with --action install first, or pass the correct --install-dir." >&2
    exit 1
  fi
  echo "Checking Unsloth Studio for updates..."
  "$unsloth_bin" studio update
  write_launcher
  echo "Unsloth Studio is up to date."
  exit 0
fi

echo "==> Installing prerequisites"
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y curl git build-essential python3 python3-venv
fi

echo "Installing Unsloth Studio to: $install_dir"
echo "Hugging Face models will be cached in: $hub_cache_dir"
echo "NVIDIA/AMD GPU support is detected and configured by Unsloth's official installer."

installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT
curl -fsSL https://unsloth.ai/install.sh -o "$installer"
bash "$installer"
write_launcher

cat <<EOF

Done. Start Unsloth Studio with:
  $install_dir/start.sh
then open http://localhost:8888
EOF
