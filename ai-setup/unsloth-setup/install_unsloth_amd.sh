#!/usr/bin/env bash
# Installs Unsloth Core for AMD in a dedicated WSL virtual environment.
set -euo pipefail

install_dir="/mnt/e/UnslothAMD"
rocm_index_url="https://download.pytorch.org/whl/rocm7.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) install_dir="$2"; shift 2 ;;
    --rocm-index-url) rocm_index_url="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ ! "$install_dir" =~ ^/mnt/[a-zA-Z]/ ]]; then
  echo "Install directory must be on a mounted Windows drive (for example /mnt/e/UnslothAMD)." >&2
  exit 2
fi

echo "==> Installing Linux prerequisites"
sudo apt update
sudo apt install -y python3 python3-full python3-pip python3-venv git

echo "==> Creating environment: $install_dir/venv"
mkdir -p "$install_dir"
python3 -m venv "$install_dir/venv"
python="$install_dir/venv/bin/python"

"$python" -m pip install --upgrade pip

echo "==> Installing AMD ROCm PyTorch from $rocm_index_url"
"$python" -m pip install --upgrade --force-reinstall \
  torch torchvision torchaudio --index-url "$rocm_index_url"

echo "==> Installing Unsloth's AMD branch"
"$python" -m pip install --no-deps unsloth unsloth-zoo
"$python" -m pip install --no-deps git+https://github.com/unslothai/unsloth-zoo.git
"$python" -m pip install "unsloth[amd] @ git+https://github.com/unslothai/unsloth"

echo
echo "Done. In WSL, activate the environment with:"
echo "  source '$install_dir/venv/bin/activate'"
echo "Verify ROCm/PyTorch with:"
echo "  $python -c \"import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'No AMD GPU found')\""
