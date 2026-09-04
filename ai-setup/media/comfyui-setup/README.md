# comfyui-setup

Script to set up [ComfyUI](https://github.com/comfyanonymous/ComfyUI) on
Windows: clones the repo, creates an isolated Python venv, installs PyTorch
(NVIDIA CUDA, AMD ROCm-on-Windows preview, or CPU - auto-detected from the
GPU present), installs ComfyUI's dependencies, installs
[ComfyUI-Manager](https://github.com/ltdrdata/ComfyUI-Manager) (custom node
installer + model browser) into `custom_nodes`, sets up
[joenorton/comfyui-mcp-server](https://github.com/joenorton/comfyui-mcp-server)
(a standalone MCP server that drives a running ComfyUI instance) in its own
sibling venv, and pre-downloads a default checkpoint so ComfyUI has something
to generate with immediately.

Same GPU-detection/install pattern as
[`../ai-setup/gaming/hunyuan3d2-setup`](../ai-setup/gaming/hunyuan3d2-setup) in this repo. Hunyuan3D-2 itself
is set up separately there, not by this script - see that folder if you want
image/text -> 3D generation; this one is for ComfyUI's own
diffusion-model workflows (image/video generation, ControlNet, etc.).

## Scripts

| Script | Purpose |
|---|---|
| `setup_comfyui_env.ps1` | Clone/update ComfyUI, set up the venv/PyTorch/deps, install ComfyUI-Manager + comfyui-mcp-server, download default models |
| `setup_comfyui_env.bat` | Double-clickable wrapper that runs the .ps1 with the execution policy bypassed |
| `setup_comfyui_env_amd.bat` | Same, but forces `-GpuVendor Amd` - no arguments needed for AMD GPUs |

---

## setup_comfyui_env.ps1

If your PowerShell execution policy blocks running local `.ps1` files (the
default on most Windows installs), either double-click
`setup_comfyui_env.bat` (or run it from `cmd.exe`, forwarding any
arguments), or run the `.ps1` directly with the policy bypassed for that one
process:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_comfyui_env.ps1 [args...]
```

Otherwise, from an elevated PowerShell prompt (winget installs may prompt for
UAC):

```powershell
./setup_comfyui_env.ps1 [-Action <Install|Update|Start>] [-InstallDir <path>] [-McpDir <path>] [-ComfyPort <port>] [-GpuVendor <Auto|Nvidia|Amd|Cpu>] [-CudaVersion <tag>] [-RocmVersion <ver>] [-Models <entries>] [-Skip...]
```

| Argument | Default | Description |
|---|---|---|
| `-Action` | `Install` | `Install` clones ComfyUI/ComfyUI-Manager/comfyui-mcp-server into `-InstallDir`/`-McpDir` and sets everything up (skips any that are already cloned there). `Update` `git pull --ff-only`s each at its existing path and reinstalls requirements - errors out if `-InstallDir` isn't an existing ComfyUI checkout yet. `Start` launches both ComfyUI and comfyui-mcp-server as detached background processes - see [Starting via the script](#starting-via-the-script) below. `ListNodes` prints the node-pack catalog, `InstallNode` installs one - see [Installing node packs](#installing-node-packs) below |
| `-InstallDir` | prompted if omitted (default `%USERPROFILE%\ComfyUI`) | Path to install ComfyUI to (`-Action Install`), the existing install to update/start/extend (`-Action Update`/`Start`/`InstallNode`) |
| `-McpDir` | `%USERPROFILE%\comfyui-mcp-server` | Same, for comfyui-mcp-server's own venv |
| `-ComfyPort` | `8188` | `-Action Start` only. Starting port to try for ComfyUI - if occupied by something that isn't already *this* install running, the next port is tried (up to +20) until a free one is found |
| `-Node` | none | `-Action InstallNode` only. Catalog key to install - see `-Action ListNodes` |
| `-SkipTextureWheel` | off | `-Action InstallNode` only. Skip installing the precompiled `custom_rasterizer` texture-generation wheel on the NVIDIA path |
| `-GpuVendor` | `Auto` | Which PyTorch install path to use: `Auto` (detect NVIDIA -> AMD -> CPU), or force `Nvidia`/`Amd`/`Cpu` |
| `-CudaVersion` | `cu124` | NVIDIA path only: PyTorch CUDA wheel tag (`cu118`/`cu121`/`cu124`/`cu126`/`cu128`) |
| `-RocmVersion` | `7.2.1` | AMD path only: AMD Windows ROCm preview release to install wheels from |
| `-Models` | SD1.5 fp16 checkpoint (see below) | Array of `"repo_id\|filename\|models-subfolder"` entries to download via `huggingface_hub` into `<InstallDir>\models\<subfolder>` |
| `-SkipGitInstall` | off | Skip installing Git |
| `-SkipPythonInstall` | off | Skip installing Python |
| `-SkipRepoClone` | off | Skip cloning/updating ComfyUI |
| `-SkipVenv` | off | Skip creating ComfyUI's venv |
| `-SkipTorchInstall` | off | Skip installing PyTorch |
| `-SkipRequirements` | off | Skip `pip install -r requirements.txt` for ComfyUI |
| `-SkipManager` | off | Skip installing ComfyUI-Manager |
| `-SkipMcpServer` | off | Skip installing comfyui-mcp-server |
| `-SkipModelDownload` | off | Skip downloading `-Models` |

### What it does

1. Installs **Git** and **Python** via `winget` if not already present (3.11
   normally, or 3.12 specifically on the AMD path - AMD's ROCm wheels are
   `cp312`-only).
2. Clones `comfyanonymous/ComfyUI` into `-InstallDir` (`-Action Install`), or
   `git pull --ff-only`s the existing checkout there (`-Action Update`).
3. Creates a venv at `<InstallDir>\venv`.
4. Installs **PyTorch**, auto-detecting the GPU vendor (NVIDIA via
   `nvidia-smi`/WMI, then AMD via WMI, else CPU) unless `-GpuVendor` forces
   one:
   - **NVIDIA** -> CUDA wheel from the official PyTorch index (`cu124` by default).
   - **AMD** -> AMD's official Windows ROCm preview wheels from
     `repo.radeon.com` (ROCm 7.2.1 / PyTorch 2.9.1 by default). Needs the
     26.2.2+ Adrenalin driver installed separately - this script does not
     touch GPU drivers.
   - **Neither found** -> CPU-only wheel (works, but generation will be very slow).
5. Installs ComfyUI's `requirements.txt`.
6. Clones **ComfyUI-Manager** into `<InstallDir>\custom_nodes\ComfyUI-Manager`
   and installs its requirements. Gives you an in-UI "Manager" button for
   installing/updating custom nodes and browsing/downloading models -
   the general-purpose way to pull in whatever models a workflow needs beyond
   the `-Models` default.
7. Clones **comfyui-mcp-server** into `-McpDir` with its **own** venv
   (separate from ComfyUI's - it has no GPU/torch dependency and talks to
   ComfyUI over HTTP/WS, so it doesn't need to live inside `-InstallDir`) and
   installs its requirements, then force-installs `mcp<2` over whatever that
   pulled in. Upstream's `requirements.txt` only pins `mcp>=0.9.0`, which
   currently resolves to `mcp` 2.x - but `server.py` imports
   `mcp.server.fastmcp.FastMCP`, an API renamed/restructured in `mcp` 2.x, so
   the server crashes at import time (`ModuleNotFoundError`) until pinned
   back to the last 1.x release.
8. Downloads the models listed in `-Models` via
   `huggingface_hub.hf_hub_download` into `<InstallDir>\models\<subfolder>`,
   skipping any file already present. Installs `pip-system-certs` into
   ComfyUI's venv first - without it, this step (raw HTTPS calls from Python,
   not through `pip`/`winget`) can fail with `CERTIFICATE_VERIFY_FAILED:
   unable to get local issuer certificate` on machines where
   antivirus/firewall software intercepts HTTPS with its own locally-trusted
   root cert that Python's bundled cert list doesn't know about. Gated/paid
   HF repos need `$env:HF_TOKEN` set before running.

Each step is best-effort and non-fatal where it can be: if `winget` isn't
available, or a step fails, the script warns and continues so you can finish
that step manually and re-run with the earlier steps skipped.

### Default model

`-Models` defaults to a single entry:
`Comfy-Org/stable-diffusion-v1-5-archive|v1-5-pruned-emaonly-fp16.safetensors|checkpoints`
- a ~2.1 GB re-upload of Stable Diffusion 1.5 (the original
`runwayml/stable-diffusion-v1-5` HF repo was taken down; this is the
community/Comfy-Org mirror), downloaded to
`<InstallDir>\models\checkpoints\`. It's enough to run ComfyUI's default
text-to-image workflow immediately after setup. For anything else
(SDXL, video models, ControlNets, LoRAs, upscalers, ...) either:
- pass your own `-Models "repo_id|filename|subfolder"` entries (repeatable), or
- use ComfyUI-Manager's **Model Manager** tab in the running UI, which is
  the better option for large/curated model lists since it knows the correct
  subfolder and dedupes for you.

### Updating

Re-run with `-Action Update -InstallDir <same path>` to `git pull --ff-only`
ComfyUI, ComfyUI-Manager, and comfyui-mcp-server to their latest version and
reinstall their requirements, without re-downloading models or reinstalling
Git/Python/PyTorch:

```powershell
./setup_comfyui_env.ps1 -Action Update -InstallDir D:\AI\ComfyUI -SkipModelDownload -SkipTorchInstall -SkipGitInstall -SkipPythonInstall
```

(`-SkipModelDownload` is optional - drop it if you also want to pick up any
newly-added `-Models` entries. `-InstallDir` must point at an existing
ComfyUI checkout - `-Action Update` errors out otherwise.)

### Examples

```powershell
# Full install with defaults (auto-detected GPU vendor, default SD1.5 checkpoint)
./setup_comfyui_env.ps1

# Same, explicit
./setup_comfyui_env.ps1 -Action Install -InstallDir D:\AI\ComfyUI

# AMD GPU (e.g. Radeon AI PRO R9700) - forces the ROCm path explicitly
./setup_comfyui_env.ps1 -GpuVendor Amd

# Keep everything on D: instead of the system drive
./setup_comfyui_env.ps1 -InstallDir D:\AI\ComfyUI -McpDir D:\AI\comfyui-mcp-server

# Skip the default checkpoint, pull in an SDXL base model instead
./setup_comfyui_env.ps1 -Models "stabilityai/stable-diffusion-xl-base-1.0|sd_xl_base_1.0.safetensors|checkpoints"

# Update an existing install (pull latest ComfyUI/Manager/MCP server, reinstall deps)
./setup_comfyui_env.ps1 -Action Update -InstallDir D:\AI\ComfyUI -SkipModelDownload -SkipTorchInstall -SkipGitInstall -SkipPythonInstall

# Launch both ComfyUI and comfyui-mcp-server (see "Starting via the script" below)
./setup_comfyui_env.ps1 -Action Start -InstallDir D:\AI\ComfyUI -McpDir D:\AI\comfyui-mcp-server

# See what node packs can be installed, then install one (see "Installing node packs" below)
./setup_comfyui_env.ps1 -Action ListNodes -InstallDir D:\AI\ComfyUI
./setup_comfyui_env.ps1 -Action InstallNode -Node Hunyuan3D2 -InstallDir D:\AI\ComfyUI
```

---

## Installing node packs

`-Action InstallNode` adds a custom node pack (and anything it specifically
needs) into an existing ComfyUI install. `-Action ListNodes` prints what's
currently in the catalog - right now just one entry:

| `-Node` key | Installs | Variants supported |
|---|---|---|
| `Hunyuan3D2` | [kijai/ComfyUI-Hunyuan3DWrapper](https://github.com/kijai/ComfyUI-Hunyuan3DWrapper) | Hunyuan3D-2 (standard), -2-mv (multiview), -2-mv-fast, -2-0-fast, -2.1, mini |

```powershell
./setup_comfyui_env.ps1 -Action InstallNode -Node Hunyuan3D2 -InstallDir "<InstallDir>"
```

What it does:
- Clones the node pack into `<InstallDir>\custom_nodes\<pack>` (or `git pull`s
  it if `-Action Update` was used previously - node packs aren't touched by
  `-Action Update` directly, re-run `InstallNode` to pull a pack's updates)
  and installs its `requirements.txt` into ComfyUI's own venv (custom nodes
  run in-process with ComfyUI, unlike comfyui-mcp-server).
- **Models**: none are pre-downloaded by this step. `Hunyuan3D2`'s
  `DownloadAndLoad*` nodes fetch whichever shape checkpoint you pick from
  their dropdown (2.0, -mv, -mv-fast, -0-fast, 2.1, mini) automatically the
  first time you queue a workflow that uses them - multi-GB per variant, so
  only what you actually select gets downloaded, not everything.
- Copies the pack's example workflows (if it ships any) into
  `<InstallDir>\user\default\workflows\<pack>`, so they show up as a ready
  starting point in ComfyUI's Workflows sidebar instead of building one from
  the node graph from scratch - `Hunyuan3D2` ships a basic and a multiview
  example.
- **Texture generation (`Hunyuan3D2` only) works on every GPU path**,
  including AMD/ROCm and CPU, via two layers:
  - **NVIDIA**: installs the precompiled `custom_rasterizer` CUDA wheel
    (Windows, cp312) shipped inside the pack's own repo, picking the one
    that best matches your installed torch/CUDA build (best-effort - install
    a different one from the pack's `wheels\` folder by hand if generation
    errors on a version mismatch). This is the fast, native path.
  - **Every path, always**: installs `vendor/torch_rasterizer.py`, a
    pure-PyTorch reimplementation of the same rasterizer (verified against a
    literal transcription of the native kernel's C++ logic - no compiler or
    toolchain needed anywhere, runs on whatever device the tensors are on),
    plus `vendor/hunyuan3d2-torch-rasterizer.patch`, which teaches
    `mesh_render.py` to fall back to it automatically when
    `import custom_rasterizer` fails - which on **AMD/ROCm it always does**,
    since the ROCm Windows torch wheel can't link *any* C++ extension at
    all (GPU or CPU variant), so the native kernel is never buildable there.
    The patch is idempotent (`git apply --reverse --check` skips cleanly if
    already applied, same convention as
    [`../ai-setup/gaming/hunyuan3d2-setup`](../ai-setup/gaming/hunyuan3d2-setup)'s `windows-fixes.patch`) and
    warns instead of failing if upstream changes the file enough that it no
    longer applies. On NVIDIA this is a pure safety net - the native
    extension is always tried first and only skipped on `ImportError` - so
    installing it is never a downgrade there, only a fallback for when the
    wheel doesn't match your exact torch/CUDA build. On AMD/ROCm/CPU it's
    the only path, and is slower than a native CUDA build accordingly.
    Verified end-to-end on an AMD Radeon AI PRO R9700 (ROCm 7.2.1): a real
    mesh rasterizes correctly on `cuda:0` (ROCm's device string) with no
    compiled extension present.

### Examples

```powershell
# See what's available
./setup_comfyui_env.ps1 -Action ListNodes -InstallDir D:\AI\ComfyUI

# Install Hunyuan3D-2 (shape + texture generation both work on any GPU path)
./setup_comfyui_env.ps1 -Action InstallNode -Node Hunyuan3D2 -InstallDir D:\AI\ComfyUI

# NVIDIA, but skip the texture wheel (e.g. venv isn't Python 3.12)
./setup_comfyui_env.ps1 -Action InstallNode -Node Hunyuan3D2 -InstallDir D:\AI\ComfyUI -SkipTextureWheel
```

---

## Starting via the script

`-Action Start` launches ComfyUI and comfyui-mcp-server as detached
background processes and returns - no need to keep a terminal window open,
and no manual `python.exe main.py`/`python.exe server.py` typing:

```powershell
./setup_comfyui_env.ps1 -Action Start -InstallDir "<InstallDir>" -McpDir "<McpDir>"
```

What it does:
- Tries `-ComfyPort` (8188 by default) for ComfyUI. If something's already
  listening there, it checks whether that something is *this* `-InstallDir`'s
  ComfyUI already running (in which case it's reused, nothing new launched)
  or something else entirely - another ComfyUI install, some unrelated
  service - in which case it walks forward to the next free port instead
  (8189, 8190, ...) rather than colliding with it. Logs to
  `<InstallDir>\comfyui.log`, waits up to 2 minutes for `/system_stats` to
  respond before reporting readiness.
- Launches comfyui-mcp-server (fixed port 9000 - not configurable upstream)
  with `COMFYUI_URL` pointed at whichever port ComfyUI ended up on. Skipped
  if port 9000 is already answering (assumed already running). Logs to
  `<McpDir>\mcp-server.log`.
- Re-running `-Action Start` is safe - it detects and reuses already-running
  instances instead of launching duplicates.

Find/stop the processes later:
```powershell
Get-Process python | Where-Object { $_.Path -like "*<InstallDir>*" -or $_.Path -like "*<McpDir>*" } | Stop-Process
```

**AMD/ROCm:** verify the GPU is picked up:
```powershell
& "<InstallDir>\venv\Scripts\python.exe" -c "import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0))"
```

### Running manually instead

Everything lives inside its own venv - nothing needs "activating"; call the
venv's `python.exe` directly (see the
[hunyuan3d2-setup README](../ai-setup/gaming/hunyuan3d2-setup/README.md#how-to-run-hunyuan3d-2)
for why `Activate.ps1`/`activate.bat` are finicky in PowerShell if you'd
rather activate manually).

```powershell
# 1. ComfyUI
cd "<InstallDir>"
& "<InstallDir>\venv\Scripts\python.exe" main.py --port 8188

# 2. comfyui-mcp-server, in a separate window, once ComfyUI is up
cd "<McpDir>"
& "<McpDir>\venv\Scripts\python.exe" server.py
```

Open **http://127.0.0.1:8188** for the ComfyUI UI - ComfyUI-Manager adds a
"Manager" button in the top bar for installing custom nodes and
browsing/downloading models. comfyui-mcp-server listens at
`http://127.0.0.1:9000/mcp`. Register it with an MCP client by adding to
`.mcp.json`:

```json
{
  "mcpServers": {
    "comfyui-mcp-server": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:9000/mcp"
    }
  }
}
```

Some MCP clients expect `"type": "http"` instead of `"streamable-http"` - try
both if auto-discovery fails. See
[joenorton/comfyui-mcp-server](https://github.com/joenorton/comfyui-mcp-server)
for its workflow-selection format and `COMFY_MCP_*` environment variables
(e.g. `COMFY_MCP_DEFAULT_STEPS`).

### Notes

- **GPU auto-detection** cross-checks Windows' own device list (WMI), not
  just whether `nvidia-smi.exe` exists on PATH - some machines have a
  stray/leftover `nvidia-smi.exe` with no real NVIDIA GPU present (e.g. from
  an old driver installer), where relying on it alone would misdetect
  `Nvidia` on an AMD-only box. Force the right path with `-GpuVendor` if
  auto-detection ever gets it wrong for your machine.
- **License** - review ComfyUI's own license, and each downloaded model's
  license (the default SD1.5 checkpoint is CreativeML OpenRAIL-M), before
  any commercial use.
- **Disk space** - ComfyUI itself is small; models are the multi-GB cost.
  Point `-InstallDir` at a drive with room before running if the system
  drive is tight - there's no separate model-cache redirect like
  hunyuan3d2-setup's `-ModelCacheDir` since models live directly under
  `<InstallDir>\models\`.
