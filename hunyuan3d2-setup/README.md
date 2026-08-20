# hunyuan3d2-setup

Script to set up [Tencent Hunyuan3D-2](https://github.com/Tencent-Hunyuan/Hunyuan3D-2)
(image/text -> 3D mesh + PBR texture generation) on Windows: clones the repo,
creates an isolated Python venv, installs PyTorch (NVIDIA CUDA, AMD
ROCm-on-Windows preview, or CPU - auto-detected from the GPU present),
installs the project's dependencies, best-effort builds the two extensions
needed for texture generation, and pre-downloads the model weights from
HuggingFace.

**AMD GPUs (e.g. Radeon AI PRO R9700 / RDNA4):** shape generation works via
AMD's official Windows ROCm preview PyTorch wheels. Texture generation does
not - `custom_rasterizer` is a raw CUDA extension with no HIP port upstream,
so it can't build against an AMD GPU. See [AMD/ROCm](#amdrocm-r9700-etc)
below.

## Scripts

| Script | Purpose |
|---|---|
| `setup_hunyuan3d2_env.ps1` | Clone the repo, set up the venv/PyTorch/deps, build extensions, download weights |
| `setup_hunyuan3d2_env.bat` | Double-clickable wrapper that runs the .ps1 with the execution policy bypassed |
| `setup_hunyuan3d2_env_amd.bat` | Same, but forces `-GpuVendor Amd` - no arguments needed for AMD GPUs |
| `windows-fixes.patch` | Two small upstream bug fixes applied automatically after cloning - see [Windows fixes patch](#windows-fixes-patch) |

---

## setup_hunyuan3d2_env.ps1

If your PowerShell execution policy blocks running local `.ps1` files (the
default on most Windows installs), either double-click
`setup_hunyuan3d2_env.bat` (or run it from `cmd.exe`, forwarding any
arguments), or run the `.ps1` directly with the policy bypassed for that one
process:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_hunyuan3d2_env.ps1 [args...]
```

`-ExecutionPolicy Bypass` only affects this one process - it does not change
your system-wide policy, so nothing else on the machine is weakened.

Otherwise, from an elevated PowerShell prompt (winget installs may prompt for
UAC):

```powershell
./setup_hunyuan3d2_env.ps1 [-InstallDir <path>] [-ModelRepo <repo>] [-GpuVendor <Auto|Nvidia|Amd|Cpu>] [-CudaVersion <tag>] [-RocmVersion <ver>] [-Skip...]
```

| Argument | Default | Description |
|---|---|---|
| `-InstallDir` | prompted if omitted (default `%USERPROFILE%\Hunyuan3D-2`) | Where to clone the repo and create the venv. If not passed, the script prompts for it interactively (press Enter to accept the default) - pass it explicitly to skip the prompt for non-interactive/scripted runs |
| `-ModelRepo` | `tencent/Hunyuan3D-2` | Which HuggingFace model repo to download - see [Model variants](#model-variants) |
| `-ModelCacheDir` | `%USERPROFILE%\.cache\huggingface` (HF's default) | Where to cache downloaded model weights (sets `HF_HOME`). Independent of `-InstallDir` - useful to redirect off the system drive |
| `-GpuVendor` | `Auto` | Which PyTorch install path to use: `Auto` (detect NVIDIA -> AMD -> CPU), or force `Nvidia`/`Amd`/`Cpu` |
| `-CudaVersion` | `cu124` | NVIDIA path only: PyTorch CUDA wheel tag (`cu118`/`cu121`/`cu124`/`cu126`/`cu128`) |
| `-RocmVersion` | `7.2.1` | AMD path only: AMD Windows ROCm preview release to install wheels from |
| `-SkipGitInstall` | off | Skip installing Git |
| `-SkipPythonInstall` | off | Skip installing Python |
| `-SkipRepoClone` | off | Skip cloning/updating the repo |
| `-SkipWindowsPatch` | off | Skip applying `windows-fixes.patch` - see [Windows fixes patch](#windows-fixes-patch) |
| `-SkipVenv` | off | Skip creating the venv |
| `-SkipTorchInstall` | off | Skip installing PyTorch |
| `-SkipRequirements` | off | Skip `pip install -r requirements.txt` / `pip install -e .` |
| `-SkipCustomRasterizerBuild` | off | Skip building the texture-generation extensions |
| `-SkipModelDownload` | off | Skip pre-downloading model weights |

### What it does

1. Installs **Git** via `winget` if not already present. Installs **Python**
   if not already present: 3.11 normally, or 3.12 specifically on the AMD
   path (AMD's ROCm wheels are `cp312`-only).
2. Clones `Tencent-Hunyuan/Hunyuan3D-2` into `-InstallDir` (skips if already cloned).
3. Applies `windows-fixes.patch` (see [below](#windows-fixes-patch)) - detects
   and skips cleanly if already applied, warns (doesn't fail the run) if it
   no longer applies because upstream changed.
5. Creates a venv at `<InstallDir>\venv` (via `py -3.12` on the AMD path).
6. Installs **PyTorch**, auto-detecting the GPU vendor (NVIDIA via
   `nvidia-smi`/WMI, then AMD via WMI, else CPU) unless `-GpuVendor` forces one:
   - **NVIDIA** -> CUDA wheel from the official PyTorch index (`cu124` by default).
   - **AMD** -> AMD's official Windows ROCm preview wheels from
     `repo.radeon.com` (ROCm 7.2.1 / PyTorch 2.9.1 by default). Needs the
     26.2.2+ Adrenalin driver installed separately - this script does not
     touch GPU drivers.
   - **Neither found** -> CPU-only wheel (works, but shape/texture generation
     will be very slow - the project normally expects 6-16 GB of VRAM).
7. Installs `requirements.txt` and the package itself (`pip install -e .`),
   plus:
   - `sentencepiece` - `requirements.txt` leaves it commented out, but
     without it `gradio_app.py --enable_t23d` (text-to-3D) fails at startup.
   - Swaps `onnxruntime` (installed by `requirements.txt`, CPU-only on
     Windows) for **`onnxruntime-directml`**, so `rembg` (background
     removal, used by every generation) runs on the GPU via DirectML instead
     of system RAM. Paired with the `DmlExecutionProvider` change in
     `windows-fixes.patch`.
8. **Best-effort** builds `custom_rasterizer` and `differentiable_renderer`
   (`hy3dgen/texgen/*`), the CUDA-only C++ extensions texture generation
   needs. On the **NVIDIA** path this requires `cl.exe` (MSVC) and `nvcc`
   (CUDA Toolkit matching the installed PyTorch build) on `PATH` - the script
   detects both first and **skips the build with instructions instead of
   silently installing multi-GB toolkits** if either is missing. On the
   **AMD** path the build is **always skipped** - these extensions have no
   HIP/ROCm port upstream, so they cannot build against an AMD GPU regardless
   of what's installed. Shape generation works fine on both paths without them.
9. Pre-downloads the selected model repo's weights via
   `huggingface_hub.snapshot_download`, so the first `from_pretrained(...)`
   call in your own code doesn't block on a multi-GB download. Caches to
   `%USERPROFILE%\.cache\huggingface` by default, or `-ModelCacheDir` if set.
   Also installs `pip-system-certs` into the venv first - without it, this
   step (and only this step, since it's the one making raw HTTPS calls in
   Python rather than through `pip`/`winget`) can fail with
   `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate` on
   machines where antivirus/firewall software (Norton, etc.) intercepts HTTPS
   with its own locally-trusted root cert that Python's bundled cert list
   doesn't know about.

Each step is best-effort and non-fatal where it can be: if `winget` isn't
available, or a step fails, the script warns and continues so you can finish
that step manually and re-run with the earlier steps skipped.

### Model variants

| `-ModelRepo` value | Size | Notes |
|---|---|---|
| `tencent/Hunyuan3D-2` (default) | 1.1B | Standard - shape + texture in one repo |
| `tencent/Hunyuan3D-2mini` | 0.6B | Smaller/faster, lower VRAM |
| `tencent/Hunyuan3D-2mv` | 1.1B | Multiview-conditioned shape generation |
| `tencent/Hunyuan3D-2.1` | - | Newer major version |

### Windows fixes patch

`windows-fixes.patch` fixes two bugs found running this project on Windows
(not AMD-specific - both apply on NVIDIA too). Applied automatically after
cloning (step 3 above); pass `-SkipWindowsPatch` to skip it, or apply/inspect
it by hand:
```powershell
cd "<InstallDir>"
git apply "<path to>\windows-fixes.patch"
```

1. **`api_server.py`'s model subfolder has no CLI override.** It's
   hardcoded to `hunyuan3d-dit-v2-mini-turbo` (the `tencent/Hunyuan3D-2mini`
   layout), so passing `--model_path tencent/Hunyuan3D-2` (or `-2mv`/`-2.1`)
   fails to find that subfolder in the downloaded snapshot. The patch adds a
   `--subfolder` flag, mirroring the one `gradio_app.py` already has:
   ```powershell
   .\venv\Scripts\python.exe api_server.py --model_path tencent/Hunyuan3D-2 --subfolder hunyuan3d-dit-v2-0 --device cuda
   ```
2. **`rembg` (background removal, used on every generation) silently runs
   on CPU.** `hy3dgen/rembg.py` lets `rembg` auto-pick its `onnxruntime`
   execution provider, which only checks for CUDA/ROCm/OpenVINO and falls
   back to CPU - and there's no Windows ROCm `onnxruntime` build, so on AMD
   (and on NVIDIA too, unless you separately install `onnxruntime-gpu`) this
   quietly burns system RAM instead of GPU VRAM for a step that runs on
   every single generation. Under memory pressure (e.g. several
   Hunyuan3D-2 processes running at once) it fails outright:
   `onnxruntime.capi.onnxruntime_pybind11_state.Fail: ... Failed to allocate
   memory for requested buffer`. The patch makes it explicitly request
   `DmlExecutionProvider` (DirectML - works on any DX12 GPU: NVIDIA/AMD/Intel),
   paired with the setup script swapping in `onnxruntime-directml` (step 7).

The patch is idempotent - re-running the setup script detects if it's
already applied (via `git apply --reverse --check`) and skips cleanly rather
than erroring. If upstream changes these files enough that the patch stops
applying, the script warns and continues rather than failing the whole run;
apply the equivalent change by hand in that case.

### AMD/ROCm (R9700, etc.)

Shape generation works on AMD via
[AMD's official Windows ROCm preview PyTorch wheels](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installrad/windows/install-pytorch.html)
(currently PyTorch 2.9.1 + ROCm 7.2.1, supporting RDNA4/gfx1201 cards like the
Radeon AI PRO R9700). **Texture generation does not work** - `custom_rasterizer`
is a raw CUDA extension (`nvcc`, `.cu` kernels) with no HIP port upstream, so
it cannot be built against an AMD GPU no matter what's installed; the script
skips that build step unconditionally on this path.

Prerequisites this script does **not** install for you:
- The **26.2.2+ Adrenalin driver** (GPU driver updates aren't scripted here -
  install it yourself from AMD's site first).

The AMD wheel URLs/versions in this script (ROCm `7.2.1`, PyTorch `2.9.1`) are
pinned to what AMD currently publishes and will go stale as they ship new
releases - check the docs link above and pass `-RocmVersion` (and update the
script's `torch`/`torchvision`/`torchaudio` version strings if AMD bumps
those too) if the pinned URLs 404.

Verify PyTorch sees the GPU after setup:
```powershell
& "$InstallDir\venv\Scripts\python.exe" -c "import torch; print(torch.cuda.is_available())"
```

### Manual steps / notes

- **Texture generation build failures on NVIDIA/Windows** are the most common
  friction point with this project - `custom_rasterizer` is a CUDA extension
  and needs an exact MSVC + CUDA Toolkit setup. If the automated build keeps
  failing after installing both, the community-maintained
  [Hunyuan3D-2-WinPortable](https://github.com/YanWenKun/Hunyuan3D-2-WinPortable)
  bundle avoids the compile step entirely and is what the upstream README
  itself points Windows users to.
- **License** - review Hunyuan3D-2's own `LICENSE`/`NOTICE` in the cloned
  repo before any commercial use; Tencent ships it under a community license,
  not a permissive OSS one.
- **Re-running after a partial failure** - every step is individually
  skippable, so re-run with `-Skip...` flags for whatever already succeeded.
  For example, after installing MSVC + CUDA Toolkit by hand:
  ```powershell
  ./setup_hunyuan3d2_env.ps1 -SkipGitInstall -SkipPythonInstall -SkipRepoClone -SkipVenv -SkipTorchInstall -SkipRequirements -SkipModelDownload
  ```

### Examples

```powershell
# Full install with defaults (standard model, auto-detected GPU vendor)
./setup_hunyuan3d2_env.ps1

# AMD GPU (e.g. Radeon AI PRO R9700) - forces the ROCm path explicitly
./setup_hunyuan3d2_env.ps1 -GpuVendor Amd

# Smaller/faster model, explicit NVIDIA CUDA wheel
./setup_hunyuan3d2_env.ps1 -ModelRepo tencent/Hunyuan3D-2mini -CudaVersion cu121

# Keep the repo/venv on D: and also cache model weights there (off the system drive)
./setup_hunyuan3d2_env.ps1 -InstallDir D:\AI\Hunyuan3D-2 -ModelCacheDir D:\AI\Hunyuan3D-2\hf-cache

# Everything already installed - just (re-)download weights
./setup_hunyuan3d2_env.ps1 -SkipGitInstall -SkipPythonInstall -SkipRepoClone -SkipVenv -SkipTorchInstall -SkipRequirements -SkipCustomRasterizerBuild
```

---

## How to run Hunyuan3D-2

Once setup finishes, everything lives inside the venv at `<InstallDir>\venv` -
nothing needs "activating"; just call that venv's `python.exe` directly. All
commands below assume `<InstallDir>` and `<ModelRepo>` are whatever you passed
(or accepted as defaults) during setup.

> **Activating the venv in PowerShell:** use `Activate.ps1`, not
> `activate.bat`. Running `.\venv\Scripts\activate.bat` from a PowerShell
> prompt spawns a child `cmd.exe`, sets `PATH` inside *that* child process,
> then the child exits and the change is discarded - `python` in your
> PowerShell session still resolves to whatever was already on PATH (e.g.
> your existing Python 3.14, not the venv's 3.12). Instead:
> ```powershell
> .\venv\Scripts\Activate.ps1
> python --version   # should now say Python 3.12.x
> ```
> If that's blocked by the execution policy, relax it for just this session
> (no admin needed, nothing changes system-wide) and dot-source in the
> *same* process - do **not** wrap this in `powershell -Command "..."`,
> since that spawns a whole new nested process whose environment changes
> are discarded the moment it exits, same as the `.bat` problem above:
> ```powershell
> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
> . .\venv\Scripts\Activate.ps1
> python --version   # should now say Python 3.12.x
> ```
> Or skip activation entirely and just call
> `.\venv\Scripts\python.exe` directly, which always works regardless of
> shell or activation state - this is what every command below does.

If you used `-ModelCacheDir`, set `HF_HOME` to the same path in any *new*
shell before running your own code, so `from_pretrained(...)` finds the
existing cache instead of re-downloading:
```powershell
$env:HF_HOME = "<ModelCacheDir>"   # only needed if you passed -ModelCacheDir
```

> **Other caches this script doesn't redirect:** the Gradio demo also pulls
> in `rembg` for background removal, which downloads its own ~1 GB ONNX
> model to `%USERPROFILE%\.rembg` on first use - separate from `HF_HOME` and
> not something `-ModelCacheDir` touches. If you're steering caches off the
> system drive, also set:
> ```powershell
> $env:U2NET_HOME = "<some path on another drive>"
> ```
> before launching `gradio_app.py`.

### 1. Verify the GPU is detected

```powershell
& "<InstallDir>\venv\Scripts\python.exe" -c "import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0))"
```
Should print `True` followed by your GPU's name (confirmed working output on
an AMD Radeon AI PRO R9700: `True` / `AMD Radeon AI PRO R9700`).

### 2. Shape generation (Python one-liner)

```powershell
cd "<InstallDir>"
& "<InstallDir>\venv\Scripts\python.exe" -c "from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline; p = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained('<ModelRepo>'); p(image='assets/demo.png')[0].export('out.glb')"
```
Run from `<InstallDir>` so the relative `assets/demo.png` path resolves (or
point `image=` at your own file with a full path). Writes `out.glb` to the
current directory - open it in any glTF viewer (Windows 3D Viewer, Blender,
etc.) to check the result.

### 3. Gradio web demo

`--subfolder` must match a folder that actually exists inside the
downloaded model repo's snapshot (e.g.
`<ModelCacheDir-or-default-cache>\hub\models--tencent--Hunyuan3D-2\snapshots\<hash>\`)
- it's specific to which `-ModelRepo` you downloaded, not interchangeable.
For the default `tencent/Hunyuan3D-2` repo it's `hunyuan3d-dit-v2-0`.

**NVIDIA (with the texture-generation extensions built):**
```powershell
cd "<InstallDir>"
& "<InstallDir>\venv\Scripts\python.exe" gradio_app.py --model_path <ModelRepo> --subfolder hunyuan3d-dit-v2-0 --texgen_model_path <ModelRepo> --low_vram_mode
```

**AMD/ROCm (shape only - skip loading the texture pipeline entirely):**
```powershell
cd "<InstallDir>"
$env:HF_HOME = "<ModelCacheDir>"   # only if you passed -ModelCacheDir during setup
& "<InstallDir>\venv\Scripts\python.exe" gradio_app.py --model_path <ModelRepo> --subfolder hunyuan3d-dit-v2-0 --disable_tex
```

**AMD/ROCm, with Text-to-3D also enabled** (confirmed working - shape and
text-to-3D both run fine on ROCm, only texture generation doesn't):
```powershell
cd "<InstallDir>"
$env:HF_HOME = "<ModelCacheDir>"   # only if you passed -ModelCacheDir during setup
& "<InstallDir>\venv\Scripts\python.exe" gradio_app.py --model_path <ModelRepo> --subfolder hunyuan3d-dit-v2-0 --disable_tex --enable_t23d
```

Either way, it binds to `0.0.0.0:8080` by default (confirmed working) - open
**`http://localhost:8080`**, or pass `--port`/`--host` to change it.

`--enable_t23d` adds a Text-to-3D tab. It's a plain `diffusers` pipeline
(`hy3dgen/text2image.py`, Tencent's `HunyuanDiT-v1.1-Diffusers-Distilled`)
with no CUDA-only extensions, so it works on AMD/ROCm the same as shape
generation. First use auto-downloads that model (separate from
`<ModelRepo>`, ~14.5 GB) into the same `HF_HOME`/`-ModelCacheDir` cache.

`--enable_t23d` needs `sentencepiece` for its tokenizer - the setup script
installs it by default (step 5 above), so this is only relevant if your venv
predates that, or you passed `-SkipRequirements`:
```powershell
.\venv\Scripts\python.exe -m pip install sentencepiece
```
Without it, startup fails with `ValueError: tiktoken is required to read a
tiktoken file` (the fallback tokenizer path also isn't installed). This is
unrelated to GPU vendor - happens on NVIDIA too.

### On the AMD/ROCm path

Shape generation and text-to-3D (`--enable_t23d`) both work fine - only
**texture generation** doesn't (see [AMD/ROCm](#amdrocm-r9700-etc) above),
since `custom_rasterizer` was never built. Pass `--disable_tex` as shown
above to skip the texture pipeline cleanly; without it, `gradio_app.py`
still starts (the texgen import failure is caught) but prints a "Failed to
load texture generator" warning and disables the texture UI automatically.
