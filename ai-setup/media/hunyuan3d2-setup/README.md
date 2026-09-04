# hunyuan3d2-setup

Script to set up [Tencent Hunyuan3D-2](https://github.com/Tencent-Hunyuan/Hunyuan3D-2)
(image/text -> 3D mesh + PBR texture generation) on Windows: clones the repo,
creates an isolated Python venv, installs PyTorch (NVIDIA CUDA, AMD
ROCm-on-Windows preview, or CPU - auto-detected from the GPU present),
installs the project's dependencies, best-effort builds the native
`custom_rasterizer` extension needed for texture generation's fast path,
always installs a vendored pure-PyTorch fallback for the same rasterizer
(works on any GPU path, no compiler needed), and pre-downloads the model
weights from HuggingFace.

**AMD GPUs (e.g. Radeon AI PRO R9700 / RDNA4):** both shape AND texture
generation work, via AMD's official Windows ROCm preview PyTorch wheels plus
the pure-PyTorch rasterizer fallback (`custom_rasterizer`'s native build
itself is still CUDA-only with no HIP port upstream - the fallback is what
makes texture generation possible here at all). Verified end-to-end on a
Radeon AI PRO R9700, ROCm 7.2.1. See [AMD/ROCm](#amdrocm-r9700-etc) below.

## Scripts

| Script | Purpose |
|---|---|
| `setup_hunyuan3d2_env.ps1` | Clone the repo, set up the venv/PyTorch/deps, build/vendor texture-gen extensions, download weights |
| `setup_hunyuan3d2_env.bat` | Double-clickable wrapper that runs the .ps1 with the execution policy bypassed |
| `setup_hunyuan3d2_env_amd.bat` | Same, but forces `-GpuVendor Amd` - no arguments needed for AMD GPUs |
| `windows-fixes.patch` | Three small upstream bug fixes applied automatically after cloning - see [Windows fixes patch](#windows-fixes-patch) |
| `vendor/torch_rasterizer.py`, `vendor/torch-rasterizer-fallback.patch` | Pure-PyTorch `custom_rasterizer` fallback, installed on every GPU path - see [Texture generation on any GPU](#texture-generation-on-any-gpu) |

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
| `-SkipCustomRasterizerBuild` | off | Skip building the native `custom_rasterizer` extension (NVIDIA-only fast path) |
| `-SkipTorchRasterizerFallback` | off | Skip installing the pure-PyTorch `custom_rasterizer` fallback - see [Texture generation on any GPU](#texture-generation-on-any-gpu) |
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
8. **Best-effort** builds `custom_rasterizer` (`hy3dgen/texgen/*`), the
   CUDA-only C++ extension texture generation's native path needs. On the
   **NVIDIA** path this requires `cl.exe` (MSVC) and `nvcc` (CUDA Toolkit
   matching the installed PyTorch build) on `PATH` - the script detects both
   first and **skips the build with instructions instead of silently
   installing multi-GB toolkits** if either is missing. On the **AMD** path
   the build is **always skipped** - this extension has no HIP/ROCm port
   upstream, so it cannot build against an AMD GPU regardless of what's
   installed. Shape generation works fine on every path without it.
9. Installs the **pure-PyTorch `custom_rasterizer` fallback** - see
   [Texture generation on any GPU](#texture-generation-on-any-gpu) - on
   every GPU path, always (skip with `-SkipTorchRasterizerFallback`).
10. Pre-downloads the selected model repo's weights via
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

`windows-fixes.patch` fixes five bugs found running this project (not
actually Windows- or AMD-specific despite the name - all five apply on any
platform/GPU vendor; kept the legacy name from when it was three).  Applied
automatically after cloning (step 3 above); pass `-SkipWindowsPatch` to skip
it, or apply/inspect it by hand:
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
3. **`api_server.py` crashes on text-only requests** (no `image` in the
   request body - what `blender-mcp`'s "generate from text prompt" tool
   sends) with `AttributeError: 'ModelWorker' object has no attribute
   'pipeline_t2i'`. Upstream's `ModelWorker.__init__` has the
   text-to-image pipeline construction commented out, but `generate()`
   still calls `self.pipeline_t2i(text)` unconditionally on the text-only
   path - it's dead code no CLI flag ever turns on, unlike `gradio_app.py`
   which already gates the same pipeline behind `--enable_t23d`. The patch
   adds a matching `--enable_t23d` flag to `api_server.py` (uncommenting the
   `HunyuanDiTPipeline` construction when passed) and turns the missing-pipeline
   case into a clean `ValueError` ("Text-to-3D is disabled...") instead of an
   `AttributeError`, so image-only requests keep working unmodified and
   text-only requests fail with a clear message instead of a 404/traceback
   when the flag is omitted:
   ```powershell
   .\venv\Scripts\python.exe api_server.py --model_path tencent/Hunyuan3D-2 --subfolder hunyuan3d-dit-v2-0 --device cuda --enable_t23d
   ```
   Same `sentencepiece` requirement and ~14.5 GB first-use download as
   `gradio_app.py --enable_t23d` (see [Gradio web demo](#3-gradio-web-demo)
   below) - both load the same `hy3dgen/text2image.py` pipeline.
4. **Texture generation can OOM well before VRAM is actually full**, from
   plain PyTorch allocator fragmentation rather than a real capacity limit -
   reproduced reliably on an AMD Radeon AI PRO R9700 (32 GiB VRAM): the
   multiview texture diffusion step failed with `torch.OutOfMemoryError: HIP
   out of memory` at ~30/32 GiB used, with the error message itself
   suggesting the fix. The patch sets
   `PYTORCH_ALLOC_CONF`/`PYTORCH_HIP_ALLOC_CONF=expandable_segments:True` at
   the very top of `gradio_app.py` and `api_server.py` (before `torch`
   loads, since it must be set before the allocator initializes). Harmless
   on NVIDIA too - `PYTORCH_ALLOC_CONF` is the current CUDA-side name,
   `PYTORCH_HIP_ALLOC_CONF` is the ROCm-specific one PyTorch 2.x still
   reads; an unused one is just a no-op.
5. **`hy3dgen/texgen/utils/multiview_utils.py` fails to load the paint
   pipeline** with `ValueError: The directory ...\hunyuanpaint contains
   custom code in pipeline.py which must be executed to correctly load the
   model. ... Pass trust_remote_code=True`. Newer `diffusers` versions gate
   *any* `custom_pipeline=` path behind `trust_remote_code=True`, even a
   purely local one bundled with this repo (not fetched from the Hub) -
   which is exactly what this is, so passing it is safe. Without this fix,
   texture generation never gets past loading the multiview diffusion
   model, on any GPU vendor.

The patch is idempotent - re-running the setup script detects if it's
already applied (via `git apply --reverse --check`) and skips cleanly rather
than erroring. If upstream changes these files enough that the patch stops
applying, the script warns and continues rather than failing the whole run;
apply the equivalent change by hand in that case.

### Texture generation on any GPU

`custom_rasterizer` (the UV rasterization/baking step inside
`hy3dgen/texgen/differentiable_renderer/mesh_render.py`) is a compiled
CUDA/HIP C++ extension - on Windows it only has precompiled/buildable paths
for NVIDIA (`cl.exe` + `nvcc`), never AMD (no HIP port upstream exists).

To make texture generation work everywhere regardless, this script vendors
`vendor/torch_rasterizer.py` - a pure-PyTorch reimplementation of the same
`rasterize`/`interpolate` functions, verified against a literal
transcription of the native kernel's C++ logic - and applies
`vendor/torch-rasterizer-fallback.patch`, which teaches `mesh_render.py` to
fall back to it automatically whenever `import custom_rasterizer` fails,
instead of the pipeline erroring out or (on the AMD path in `gradio_app.py`)
silently disabling the texture UI. It needs no compiler or toolchain on any
platform and runs on whatever device the tensors are on (CUDA, ROCm, MPS,
CPU), so it also covers CPU-only setups and machines where the NVIDIA wheel
doesn't quite match the installed torch/CUDA build.

This is installed unconditionally (step 9 above, `-SkipTorchRasterizerFallback`
to opt out) and is purely additive on NVIDIA: `mesh_render.py` always tries
the native extension first and only falls back on `ImportError`, so having
both installed is never a downgrade there - only a safety net. On AMD/ROCm
or CPU, it's the only path, and is correspondingly slower than a native CUDA
build. The patch itself is idempotent (same convention as
`windows-fixes.patch` - `git apply --reverse --check` detects if it's
already applied and skips cleanly) and warns instead of failing if upstream
changes `mesh_render.py` enough that it no longer applies.

Verified end-to-end on an AMD Radeon AI PRO R9700 (ROCm 7.2.1) two ways:
constructing `MeshRender` and rasterizing a real triangle produces correct
pixel coverage on the ROCm device (`cuda:0`) with zero compiled extensions
present, and a full real run of `minimal_demo.py`'s pipeline (shape
generation -> mesh postprocessing -> delight -> multiview diffusion -> UV
bake via this fallback -> export) completed successfully end-to-end,
producing an actual textured `.glb` (shape mesh reduced 730K -> 40K faces
via `FaceReducer`, texture generation ~500s). That full run is what surfaced
fixes 4 and 5 in [Windows fixes patch](#windows-fixes-patch) above - without
them, texture generation doesn't get far enough to exercise this rasterizer
fallback at all.

### AMD/ROCm (R9700, etc.)

Shape generation works on AMD via
[AMD's official Windows ROCm preview PyTorch wheels](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installrad/windows/install-pytorch.html)
(currently PyTorch 2.9.1 + ROCm 7.2.1, supporting RDNA4/gfx1201 cards like the
Radeon AI PRO R9700). **Texture generation works too**, via the pure-PyTorch
fallback described above - `custom_rasterizer`'s native build is still
CUDA-only (`nvcc`, `.cu` kernels) with no HIP port upstream, so the script
still skips that build step unconditionally on this path, but no longer
needs to for texture generation to work.

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

- **Texture generation build failures on NVIDIA/Windows** used to be the most
  common friction point with this project - `custom_rasterizer` is a CUDA
  extension and needs an exact MSVC + CUDA Toolkit setup to build natively.
  That's no longer a blocker: this script always installs the pure-PyTorch
  fallback (see [Texture generation on any GPU](#texture-generation-on-any-gpu))
  regardless of whether the native build succeeds, so texture generation
  works either way - MSVC + CUDA Toolkit are only worth installing now if you
  want the faster native path specifically, not to unblock texture generation
  itself. If you'd still rather avoid the compile step entirely for some
  other reason, the community-maintained
  [Hunyuan3D-2-WinPortable](https://github.com/YanWenKun/Hunyuan3D-2-WinPortable)
  bundle is what the upstream README points Windows users to.
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

**Any GPU path, shape + texture** (NVIDIA uses the native `custom_rasterizer`
build if present, falls back to the pure-PyTorch rasterizer otherwise - AMD
always uses the fallback, see [Texture generation on any GPU](#texture-generation-on-any-gpu)):
```powershell
cd "<InstallDir>"
$env:HF_HOME = "<ModelCacheDir>"   # only if you passed -ModelCacheDir during setup
& "<InstallDir>\venv\Scripts\python.exe" gradio_app.py --model_path <ModelRepo> --subfolder hunyuan3d-dit-v2-0 --texgen_model_path <ModelRepo> --low_vram_mode
```

**Shape only** (skip loading the texture pipeline entirely - faster startup,
lower VRAM, if you don't need texture generation for a given run):
```powershell
cd "<InstallDir>"
$env:HF_HOME = "<ModelCacheDir>"   # only if you passed -ModelCacheDir during setup
& "<InstallDir>\venv\Scripts\python.exe" gradio_app.py --model_path <ModelRepo> --subfolder hunyuan3d-dit-v2-0 --disable_tex
```

**With Text-to-3D also enabled:**
```powershell
cd "<InstallDir>"
$env:HF_HOME = "<ModelCacheDir>"   # only if you passed -ModelCacheDir during setup
& "<InstallDir>\venv\Scripts\python.exe" gradio_app.py --model_path <ModelRepo> --subfolder hunyuan3d-dit-v2-0 --texgen_model_path <ModelRepo> --enable_t23d
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

Shape generation, texture generation, and text-to-3D (`--enable_t23d`) all
work (see [Texture generation on any GPU](#texture-generation-on-any-gpu)
above) - texture generation runs via the pure-PyTorch rasterizer fallback
since `custom_rasterizer`'s native build is never attempted on this path.
Pass `--disable_tex` only if you specifically want to skip the texture
pipeline for a faster/lower-VRAM run, not because it doesn't work.


# powershell.exe -NoProfile -Command "`$env:HF_HOME = 'D:\AI\Hunyuan3D-2\hf-cache'; & 'D:\AI\Hunyuan3D-2\venv\Scripts\python.exe' 'D:\AI\Hunyuan3D-2\api_server.py' --model_path tencent/Hunyuan3D-2 --subfolder hunyuan3d-dit-v2-0 --device cuda --enable_t23d" *> $logPath


powershell.exe -NoProfile -Command "`$env:HF_HOME = 'D:\AI\Hunyuan3D-2\hf-cache'; & 'D:\AI\Hunyuan3D-2\venv\Scripts\python.exe' 'D:\AI\Hunyuan3D-2\api_server.py' --model_path tencent/Hunyuan3D-2 --subfolder hunyuan3d-dit-v2-0 --device cuda --enable_t23d" *> $logPath 


gradio_app.py --model_path <ModelRepo> --subfolder hunyuan3d-dit-v2-0 --disable_tex
