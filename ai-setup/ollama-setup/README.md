# ollama-setup

One Ollama installation, two GPU backends. Switch between the **AMD Radeon AI PRO R9700 (ROCm)** and an **NVIDIA GPU (CUDA)** with a single command, without reinstalling anything.

```bash
./install.sh          # install / update Ollama (only downloads when a newer release exists)
./use-amd.sh          # run Ollama on the AMD R9700 (ROCm)
./use-nvidia.sh       # run Ollama on the NVIDIA GPU (CUDA)
./ollama-status.sh    # what is running, on which GPU, and is it accelerated?
./rollback.sh         # undo the last switch
./ollama-models.sh    # where models live, move them
./ollama-context.sh   # default context size
```

All scripts are self-contained in this directory and idempotent. Anything that needs root re-runs itself with `sudo`.

## How it works

Ollama's release ships all backend libraries side by side under `<prefix>/lib/ollama` (`cuda_v12`, `cuda_v13`, `rocm_*`, ...). `install.sh` installs the CPU/CUDA bundle **and** the ROCm bundle once, into one location (default `/usr/local`), so there is exactly one binary and one systemd service.

Switching only rewrites a systemd drop-in, `/etc/systemd/system/ollama.service.d/10-ollama-setup-gpu.conf`, which hides the other vendor's devices from Ollama:

| Backend | Environment written |
|---|---|
| `amd` | `CUDA_VISIBLE_DEVICES=-1`, `ROCR_VISIBLE_DEVICES=<supported AMD GPU ids>` |
| `nvidia` | `HIP_VISIBLE_DEVICES=-1`, `ROCR_VISIBLE_DEVICES=-1` (and `CUDA_VISIBLE_DEVICES=<ids>` if `NVIDIA_GPU_IDS` is set) |

Both backends also set `OLLAMA_VULKAN=0`, so Ollama only uses native ROCm or CUDA and never the bundled Vulkan backend. A switch that ends up on Vulkan is treated as a failure and rolled back.

Your own drop-ins and the main unit file are never touched.

## Installation and updating

```bash
./install.sh              # install, or update if a newer release exists
./install.sh --check      # report installed vs latest; exit code 10 if an update exists
./install.sh --force      # reinstall the current version
./install.sh --version 0.40.0   # pin a specific release
```

- The latest release is discovered from the GitHub API at run time (falls back to the `releases/latest` redirect if the API is rate limited). No versions or URLs are hard-coded.
- Nothing is downloaded when the installed version is current.
- Archives are verified against the release's `sha256sum.txt`.
- The previous binary and libraries are kept until the new version starts successfully; if it does not, they are restored automatically.
- Creates the `ollama` user and systemd unit only if missing; an existing unit is left alone.
- Requires: `curl`, `python3`, `tar`, `zstd`, `systemd`. Linux on x86_64 (CUDA + ROCm) or aarch64 (CUDA/CPU).

## Switching GPUs

```bash
./use-amd.sh
./use-nvidia.sh
./use-amd.sh --dry-run    # validate and show the config, change nothing
./use-amd.sh --force      # continue past "unsupported GPU/driver" checks
NVIDIA_GPU_IDS=1 ./use-nvidia.sh   # pin specific NVIDIA GPUs
```

Each switch:

1. Validates the target (below). Fails early, changing nothing.
2. Snapshots the current config into `.state/backups/`.
3. Writes the drop-in, restarts Ollama, waits for the API.
4. Reads Ollama's own device-discovery log to confirm the intended backend (ROCm/CUDA) was picked up.
5. On any failure (service won't start, wrong backend, CPU only) it **automatically restores the previous config** and restarts.

Running the same switch twice is a no-op. Restarting unloads loaded models; the script warns if any are loaded.

### What is validated

- **AMD:** AMD GPU on PCI, `amdgpu` loaded, `/dev/kfd` present, ROCm bundle installed, GPU's gfx target in the supported list (R9700 = `gfx1201`; read from `/sys/class/kfd`, so no system ROCm is needed). Unsupported GPUs such as an iGPU are hidden. The `ollama` user is added to `render`/`video`.
- **NVIDIA:** NVIDIA GPU on PCI, `nvidia-smi` working, driver CUDA >= 12.0, compute capability >= 5.0, CUDA bundle installed.

### Per-backend tuning

Put `KEY=VALUE` lines in `config/amd.env` or `config/nvidia.env` (e.g. `OLLAMA_FLASH_ATTENTION=1`, `HSA_OVERRIDE_GFX_VERSION=...`). They are added to the drop-in on the next switch.

## Rollback

```bash
./rollback.sh --list     # list saved configs
./rollback.sh            # restore the config from before the last switch
./rollback.sh <id>       # restore a specific one
```

The current config is snapshotted before restoring, so running `./rollback.sh` twice toggles between the two states. The last 10 snapshots are kept.

## Status

```bash
./ollama-status.sh
```

Reports Ollama version, installed backend bundles, active backend, OS/arch, every GPU (PCI, ROCm gfx target, NVIDIA driver and compute capability), ROCm/CUDA versions, service and API state, model storage, loaded models, and a final verdict on whether GPU acceleration works. Exit code `0` = GPU in use, `1` = not confirmed, `3` = Ollama not installed.

## Model storage

Models are independent of the GPU backend; switching never touches them.

The systemd service runs as the `ollama` user, so by default it stores models in `/usr/share/ollama/.ollama/models`. Models pulled by a manually started `ollama serve` as your own user go to `~/.ollama/models`, which the service does **not** see.

```bash
./ollama-models.sh                     # show the store the service uses (+ other stores that hold models)
./ollama-models.sh scan                # search for model stores
./ollama-models.sh set /data/ollama --migrate   # move to another disk, copying existing models
./ollama-models.sh reset               # back to the service default
```

`set` writes `OLLAMA_MODELS` to `20-ollama-setup-models.conf`, checks the `ollama` user can write there, copies with `rsync` when `--migrate` is given (the old store is left for you to delete), and restarts the service. `/usr/share/ollama` is not readable by regular users, so size/count use `sudo -n` when available.

## Context size

```bash
./ollama-context.sh              # show the configured default context length
./ollama-context.sh set 32k      # 8192, 32768, 32k, 128k ... (512 - 1048576)
./ollama-context.sh reset        # back to Ollama's default
```

Sets `OLLAMA_CONTEXT_LENGTH` via `30-ollama-setup-context.conf` and restarts Ollama (loaded models are unloaded). It is the default for models that don't set their own `num_ctx`: a Modelfile `PARAMETER num_ctx` (like your `*-32k` variants) or an API request overrides it. Larger contexts use more VRAM for the KV cache, multiplied by `OLLAMA_NUM_PARALLEL`. It is independent of the GPU backend, and a failed restart restores the previous value.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `/dev/kfd is missing` | amdgpu driver/firmware/kernel too old for RDNA4. Check `dmesg \| grep -i amdgpu`; install a current kernel or ROCm `amdgpu-dkms`, reboot. |
| `nvidia-smi cannot talk to the driver` | Driver not loaded or mismatched after an update: `sudo modprobe nvidia` or reboot. RTX 50-series (Blackwell) needs a recent driver (open kernel modules, 570+). |
| `No supported AMD GPU found` | Check the gfx target with `./ollama-status.sh`. Use `--force`, and/or set `HSA_OVERRIDE_GFX_VERSION` in `config/amd.env`. |
| Ollama runs on CPU | `journalctl -u ollama -n 100`, look for `inference compute`. Make sure the `ollama` user is in `render` and `video` (`id ollama`), then re-run the switch. |
| Models "disappeared" | You are looking at a different store; run `./ollama-models.sh`. |
| Switch failed | It was rolled back automatically. For manual recovery: `./rollback.sh`. |
| Download fails | Check connectivity / GitHub rate limits; the old install is untouched. Retry `./install.sh`. |
| Service won't start | `systemctl status ollama`, `journalctl -u ollama -n 50`. |

Useful variables: `OLLAMA_INSTALL_PREFIX` (first install location), `OLLAMA_API_URL`, `OLLAMA_READY_TIMEOUT` (seconds, default 90), `OLLAMA_ROCM_GFX_SUPPORTED`, `NO_COLOR`.

## Layout

```
install.sh  use-amd.sh  use-nvidia.sh  rollback.sh  ollama-status.sh  ollama-models.sh  ollama-context.sh
lib/common.sh   detection, systemd helpers, backups, validation
lib/switch.sh   shared switch + auto-rollback logic
config/         optional per-backend environment overrides
.state/         backups and lock (git-ignored, created on first run)
```
