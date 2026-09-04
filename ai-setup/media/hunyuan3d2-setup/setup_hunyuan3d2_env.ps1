#requires -Version 5.1
<#
Sets up Tencent's Hunyuan3D-2 (image/text -> 3D mesh + texture generation):
https://github.com/Tencent-Hunyuan/Hunyuan3D-2

Clones the repo, creates a Python venv, installs PyTorch (NVIDIA CUDA, AMD
ROCm-on-Windows preview, or CPU - auto-detected from the GPU present),
installs the project's requirements + package, best-effort builds the
CUDA-only C++ extension needed for texture generation's native path
(custom_rasterizer - see -SkipCustomRasterizerBuild), always installs a
vendored pure-PyTorch fallback for the same rasterizer that needs no
compiler and works on any GPU path (see -SkipTorchRasterizerFallback), and
pre-downloads the model weights from HuggingFace into the standard HF cache
so `from_pretrained(...)` doesn't re-download them on first run.

GPU paths:
  - NVIDIA: needs cl.exe (MSVC) and nvcc (CUDA Toolkit) to also build the
    native texture-generation extension; the script detects both and skips
    that build with instructions if either is missing, rather than silently
    installing multi-GB toolkits, falling back to the pure-PyTorch
    rasterizer either way. Shape generation alone does not need either path.
  - AMD (e.g. Radeon AI PRO R9700 / RDNA4, gfx1201): uses AMD's official
    Windows ROCm preview wheels (repo.radeon.com), which are Python
    3.12-only, so this script provisions Python 3.12 specifically on that
    path. custom_rasterizer is CUDA-only (nvcc, .cu kernels) with no HIP
    port upstream, so the native build is always skipped here - but texture
    generation still works via the pure-PyTorch fallback (verified
    end-to-end on a Radeon AI PRO R9700, ROCm 7.2.1), just slower than a
    native CUDA build. Shape generation runs fine on ROCm either way.
  - No GPU detected: CPU-only PyTorch (works, but very slow).

Run from an elevated PowerShell prompt (winget installs generally want one).
#>

[CmdletBinding()]
param(
    [string]$InstallDir,

    [ValidateSet("tencent/Hunyuan3D-2", "tencent/Hunyuan3D-2mini", "tencent/Hunyuan3D-2mv", "tencent/Hunyuan3D-2.1")]
    [string]$ModelRepo = "tencent/Hunyuan3D-2",

    # huggingface_hub always caches to %USERPROFILE%\.cache\huggingface
    # (HF_HOME) regardless of -InstallDir - set this to redirect it, e.g. if
    # your system drive is short on space. Leave unset to use the default.
    [string]$ModelCacheDir,

    [ValidateSet("Auto", "Nvidia", "Amd", "Cpu")]
    [string]$GpuVendor = "Auto",

    [ValidateSet("cu118", "cu121", "cu124", "cu126", "cu128")]
    [string]$CudaVersion = "cu124",

    [string]$RocmVersion = "7.2.1",

    [switch]$SkipGitInstall,
    [switch]$SkipPythonInstall,
    [switch]$SkipRepoClone,
    [switch]$SkipWindowsPatch,
    [switch]$SkipVenv,
    [switch]$SkipTorchInstall,
    [switch]$SkipRequirements,
    [switch]$SkipCustomRasterizerBuild,
    [switch]$SkipTorchRasterizerFallback,
    [switch]$SkipModelDownload
)

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/Tencent-Hunyuan/Hunyuan3D-2.git"

# Prompt for an install directory when not passed on the command line (e.g.
# double-clicking the .bat). Skips the prompt entirely when -InstallDir is
# given, so scripted/non-interactive runs never block on Read-Host.
if (-not $InstallDir) {
    $defaultInstallDir = "$HOME\Hunyuan3D-2"
    $response = Read-Host "Install directory for Hunyuan3D-2 [$defaultInstallDir]"
    $InstallDir = if ([string]::IsNullOrWhiteSpace($response)) { $defaultInstallDir } else { $response }
}

$VenvDir = Join-Path $InstallDir "venv"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$TextureExtBuilt = $false

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Warn2 {
    param([string]$Message)
    Write-Host "    [!] $Message" -ForegroundColor Yellow
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$FriendlyName
    )
    # No stderr redirect here: under $ErrorActionPreference = "Stop", PowerShell
    # turns a redirected native-command stderr line into a terminating
    # NativeCommandError, so a "not found" message from winget would abort
    # the whole script instead of just meaning "not installed".
    $installed = winget list --id $Id --exact --accept-source-agreements | Select-String -SimpleMatch $Id
    if ($installed) {
        Write-Host "    $FriendlyName already installed, skipping."
        return
    }
    Write-Host "    Installing $FriendlyName ($Id) via winget..."
    winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements --source winget
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "winget reported a non-zero exit code for $FriendlyName. It may already be installed under a different source, or need a manual install."
    }
}

function Test-NvidiaGpu {
    if (Test-CommandExists nvidia-smi) { return $true }
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'NVIDIA' }
    return [bool]$gpu
}

function Test-AmdGpu {
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'AMD|Radeon' }
    return [bool]$gpu
}

# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

if (-not (Test-CommandExists winget)) {
    Write-Error "winget was not found. Install 'App Installer' from the Microsoft Store, then re-run this script."
}

$ResolvedVendor = $GpuVendor
if ($ResolvedVendor -eq "Auto") {
    if (Test-NvidiaGpu) {
        $ResolvedVendor = "Nvidia"
    } elseif (Test-AmdGpu) {
        $ResolvedVendor = "Amd"
    } else {
        $ResolvedVendor = "Cpu"
    }
}
Write-Host "    GPU path: $ResolvedVendor $(if ($GpuVendor -eq 'Auto') { '(auto-detected)' } else { '(forced via -GpuVendor)' })"

# ---------------------------------------------------------------------------
if (-not $SkipGitInstall) {
    Write-Step "Installing Git"
    Install-WingetPackage -Id "Git.Git" -FriendlyName "Git"
} else {
    Write-Host "`n==> Skipping Git install (-SkipGitInstall)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# AMD's Windows ROCm-preview PyTorch wheels are built for cp312 only, so that
# path needs Python 3.12 specifically, provisioned alongside (not instead of)
# whatever "python" already resolves to.
if (-not $SkipPythonInstall) {
    Write-Step "Installing Python"
    if ($ResolvedVendor -eq "Amd") {
        # Don't redirect py.exe's stderr here: PowerShell wraps a redirected
        # native-command stderr line as a terminating NativeCommandError
        # under $ErrorActionPreference = "Stop", turning "3.12 not installed"
        # (which py.exe reports via stderr + exit code) into a script-ending
        # exception instead of the false we want.
        $hasPy312 = $false
        if (Test-CommandExists py) {
            & py -3.12 --version | Out-Null
            $hasPy312 = ($LASTEXITCODE -eq 0)
        }
        if ($hasPy312) {
            Write-Host "    Python 3.12 already available via the 'py' launcher, skipping install."
        } else {
            Install-WingetPackage -Id "Python.Python.3.12" -FriendlyName "Python 3.12"
        }
    } elseif (Test-CommandExists python) {
        Write-Host "    python already on PATH, skipping install."
    } else {
        Install-WingetPackage -Id "Python.Python.3.11" -FriendlyName "Python 3.11"
    }
} else {
    Write-Host "`n==> Skipping Python install (-SkipPythonInstall)" -ForegroundColor Cyan
}

if (-not (Test-CommandExists python) -and -not (Test-CommandExists git)) {
    Write-Warn2 "'python'/'git' not on PATH yet - open a new terminal so PATH picks up the winget installs, then re-run."
}

# ---------------------------------------------------------------------------
if (-not $SkipRepoClone) {
    Write-Step "Cloning Hunyuan3D-2"
    if (Test-Path (Join-Path $InstallDir ".git")) {
        Write-Host "    Repo already present at $InstallDir, skipping clone."
    } else {
        git clone $RepoUrl $InstallDir
    }
} else {
    Write-Host "`n==> Skipping repo clone (-SkipRepoClone)" -ForegroundColor Cyan
}

if (-not (Test-Path $InstallDir)) {
    Write-Error "Install directory $InstallDir does not exist. Run without -SkipRepoClone first, or point -InstallDir at an existing checkout."
}

# ---------------------------------------------------------------------------
# Five small upstream fixes, applied to gradio_app.py/api_server.py/hy3dgen
# (not Windows-specific despite the file's name - all five apply on any
# platform, "Windows fixes" is legacy naming from when it was three):
#   - api_server.py hardcodes its model subfolder with no CLI override, so it
#     can't load anything but the mini-turbo variant.
#   - hy3dgen/rembg.py lets rembg auto-pick its onnxruntime execution
#     provider, which only checks for CUDA/ROCm/OpenVINO and falls back to
#     CPU - there's no Windows ROCm onnxruntime build, so this silently runs
#     on CPU/system RAM even with a capable GPU sitting idle. Route it
#     through DirectML instead (works on any DX12 GPU: NVIDIA/AMD/Intel).
#   - api_server.py's ModelWorker has its text-to-image pipeline commented
#     out with no way to turn it on, so any text-only request (no image)
#     crashes with AttributeError: 'ModelWorker' object has no attribute
#     'pipeline_t2i'. Adds a --enable_t23d flag mirroring gradio_app.py's.
#   - gradio_app.py/api_server.py set no memory-allocator env vars, so the
#     multiview texture diffusion step can hit "out of memory" from plain
#     allocator fragmentation well before VRAM is actually full. Sets
#     PYTORCH_ALLOC_CONF/PYTORCH_HIP_ALLOC_CONF=expandable_segments:True at
#     the top of both entry points (before torch loads) - verified
#     end-to-end on an AMD Radeon AI PRO R9700 (ROCm 7.2.1), where texture
#     generation reliably OOM'd at ~30/32 GiB used without this.
#   - hy3dgen/texgen/utils/multiview_utils.py's DiffusionPipeline.from_pretrained
#     loads a local custom pipeline (hy3dgen/texgen/hunyuanpaint/pipeline.py,
#     bundled with this repo, not fetched from the Hub) without
#     trust_remote_code=True, which newer diffusers versions require even for
#     local custom_pipeline paths - fails with "contains custom code in
#     pipeline.py which must be executed to correctly load the model."
#     Passing trust_remote_code=True here is safe since it's the project's
#     own bundled code, not arbitrary remote code.
if (-not $SkipWindowsPatch) {
    Write-Step "Applying upstream fixes (subfolder CLI arg, rembg via DirectML, --enable_t23d, memory allocator config)"
    $patchFile = Join-Path $PSScriptRoot "windows-fixes.patch"
    Push-Location $InstallDir
    try {
        # No stderr redirect at all on these git apply --check calls (not
        # even to $null): under $ErrorActionPreference = "Stop", ANY
        # redirection of a failing native command's stderr - 2>$null, *>$null,
        # 2>&1 - turns it into a terminating NativeCommandError instead of
        # just a non-zero $LASTEXITCODE (same class of bug fixed earlier for
        # py.exe/winget above). Piping stdout to Out-Null is fine; git's
        # error text (if any) prints to the console, which is harmless here.
        git apply --check $patchFile | Out-Null
        if ($LASTEXITCODE -eq 0) {
            git apply $patchFile
            Write-Host "    Applied $patchFile"
        } else {
            git apply --reverse --check $patchFile | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Already applied, skipping."
            } else {
                Write-Warn2 "Patch didn't apply cleanly (upstream file may have changed) - apply it manually or diff by hand: $patchFile"
            }
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "`n==> Skipping Windows fixes patch (-SkipWindowsPatch)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
if (-not $SkipVenv) {
    Write-Step "Creating Python venv"
    if (Test-Path $VenvPython) {
        Write-Host "    venv already exists at $VenvDir, skipping."
    } elseif ($ResolvedVendor -eq "Amd") {
        py -3.12 -m venv $VenvDir
    } else {
        python -m venv $VenvDir
    }
} else {
    Write-Host "`n==> Skipping venv creation (-SkipVenv)" -ForegroundColor Cyan
}

if (-not (Test-Path $VenvPython)) {
    Write-Error "venv python not found at $VenvPython. Run without -SkipVenv first, or create it manually with 'python -m venv `"$VenvDir`"'."
}

if ($ResolvedVendor -eq "Amd") {
    $venvVersion = & $VenvPython -c "import sys; print('%d.%d' % sys.version_info[:2])"
    if ($venvVersion -ne "3.12") {
        Write-Warn2 "venv is Python $venvVersion, but AMD's ROCm-preview PyTorch wheels are cp312-only. Delete $VenvDir and re-run so it's recreated with Python 3.12."
    }
}

& $VenvPython -m pip install --upgrade pip | Out-Null

# ---------------------------------------------------------------------------
if (-not $SkipTorchInstall) {
    Write-Step "Installing PyTorch ($ResolvedVendor)"

    switch ($ResolvedVendor) {
        "Nvidia" {
            Write-Host "    Using CUDA wheel $CudaVersion. Check https://pytorch.org/get-started/locally/ if this doesn't match your driver."
            & $VenvPython -m pip install torch torchvision --index-url "https://download.pytorch.org/whl/$CudaVersion"
        }
        "Amd" {
            Write-Warn2 "Requires the 26.2.2+ Adrenalin driver (installed separately, not by this script) - see https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installrad/windows/install-pytorch.html"
            Write-Host "    Using AMD's Windows ROCm $RocmVersion preview wheels (Python 3.12, gfx1201/RDNA4)."
            $rocmBase = "https://repo.radeon.com/rocm/windows/rocm-rel-$RocmVersion"
            try {
                & $VenvPython -m pip install --no-cache-dir `
                    "$rocmBase/rocm_sdk_core-$RocmVersion-py3-none-win_amd64.whl" `
                    "$rocmBase/rocm_sdk_devel-$RocmVersion-py3-none-win_amd64.whl" `
                    "$rocmBase/rocm_sdk_libraries_custom-$RocmVersion-py3-none-win_amd64.whl" `
                    "$rocmBase/rocm-$RocmVersion.tar.gz"
                & $VenvPython -m pip install --no-cache-dir `
                    "$rocmBase/torch-2.9.1%2Brocm$RocmVersion-cp312-cp312-win_amd64.whl" `
                    "$rocmBase/torchvision-0.24.1%2Brocm$RocmVersion-cp312-cp312-win_amd64.whl" `
                    "$rocmBase/torchaudio-2.9.1%2Brocm$RocmVersion-cp312-cp312-win_amd64.whl"
            } catch {
                Write-Warn2 "ROCm/PyTorch wheel install failed: $_"
                Write-Warn2 "AMD's exact wheel filenames/versions change between ROCm releases - check the current ones at the docs URL above and adjust -RocmVersion, or install them manually."
            }
            Write-Host "    Verify GPU detection with: & `"$VenvPython`" -c `"import torch; print(torch.cuda.is_available())`""
        }
        "Cpu" {
            Write-Warn2 "No supported GPU detected/forced, installing CPU-only PyTorch. Shape/texture generation will be very slow (6-16 GB VRAM is normally recommended)."
            & $VenvPython -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
        }
    }
} else {
    Write-Host "`n==> Skipping PyTorch install (-SkipTorchInstall)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
if (-not $SkipRequirements) {
    Write-Step "Installing Python requirements"
    & $VenvPython -m pip install -r (Join-Path $InstallDir "requirements.txt")
    Push-Location $InstallDir
    try {
        & $VenvPython -m pip install -e .
    } finally {
        Pop-Location
    }
    # requirements.txt deliberately leaves this commented out, but it's a
    # small pure-wheel install needed for --enable_t23d (text-to-3D)'s
    # tokenizer - without it, gradio_app.py fails at startup with
    # "ValueError: tiktoken is required to read a tiktoken file" the moment
    # that flag is used. Installing it always so the flag works out of the box.
    & $VenvPython -m pip install sentencepiece | Out-Null

    # requirements.txt pulls in plain `onnxruntime`, which is CPU-only on
    # Windows (no CUDA/ROCm execution provider bundled). Swap it for
    # onnxruntime-directml so rembg (background removal) actually uses the
    # GPU via DirectML - works on any DX12 GPU (NVIDIA/AMD/Intel), unlike
    # ROCm/CUDA-specific onnxruntime builds. Paired with the
    # DmlExecutionProvider change in windows-fixes.patch above.
    & $VenvPython -m pip uninstall onnxruntime -y | Out-Null
    & $VenvPython -m pip install onnxruntime-directml | Out-Null
} else {
    Write-Host "`n==> Skipping requirements install (-SkipRequirements)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# custom_rasterizer and differentiable_renderer are only needed for texture
# generation (shape generation works without them) and are CUDA/C++
# extensions - they need cl.exe (MSVC) and nvcc (CUDA Toolkit) on PATH.
if (-not $SkipCustomRasterizerBuild) {
    Write-Step "Building texture-generation extensions (custom_rasterizer, differentiable_renderer)"

    if ($ResolvedVendor -eq "Amd") {
        Write-Warn2 "Skipping native build: custom_rasterizer/differentiable_renderer are CUDA-only (nvcc, raw .cu kernels) with no HIP/ROCm port upstream, so they cannot build against an AMD GPU."
        Write-Warn2 "Shape generation works over ROCm regardless. Texture generation still works too - see the pure-PyTorch fallback installed right after this step."
        $hasCl = $false
        $hasNvcc = $false
    } else {
        $hasCl = Test-CommandExists cl
        $hasNvcc = Test-CommandExists nvcc
    }

    if ($hasCl -and $hasNvcc) {
        $rasterizerDir = Join-Path $InstallDir "hy3dgen\texgen\custom_rasterizer"
        $rendererDir = Join-Path $InstallDir "hy3dgen\texgen\differentiable_renderer"
        $TextureExtBuilt = $true

        Push-Location $rasterizerDir
        try {
            & $VenvPython setup.py install
        } catch {
            Write-Warn2 "custom_rasterizer build failed: $_"
            $TextureExtBuilt = $false
        } finally {
            Pop-Location
        }

        Push-Location $rendererDir
        try {
            & $VenvPython setup.py install
        } catch {
            Write-Warn2 "differentiable_renderer build failed: $_"
            $TextureExtBuilt = $false
        } finally {
            Pop-Location
        }
    } elseif ($ResolvedVendor -eq "Nvidia") {
        Write-Warn2 "Skipping build: $(if (-not $hasCl) { 'cl.exe (MSVC) not found' }) $(if (-not $hasNvcc) { 'nvcc (CUDA Toolkit) not found' })"
        Write-Warn2 "Shape generation still works without these. For texture generation, install:"
        Write-Warn2 "  - MSVC: winget install --id Microsoft.VisualStudio.2022.BuildTools --override `"--wait --quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`""
        Write-Warn2 "  - CUDA Toolkit matching your PyTorch build: https://developer.nvidia.com/cuda-downloads"
        Write-Warn2 "then open a new shell (so cl.exe/nvcc are on PATH) and re-run with only -SkipCustomRasterizerBuild:`$false"
        Write-Warn2 "If this keeps failing, the community-maintained portable build avoids the compile step entirely: https://github.com/YanWenKun/Hunyuan3D-2-WinPortable"
    }
} else {
    Write-Host "`n==> Skipping texture-generation extension build (-SkipCustomRasterizerBuild)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Pure-PyTorch fallback for custom_rasterizer's UV-bake step, installed
# regardless of GPU vendor or whether the native build above succeeded.
# mesh_render.py already tries the native extension first and only falls
# back on ImportError, so this is a safety net on NVIDIA (never a downgrade)
# and the *only* path on AMD/ROCm, where the native extension can never be
# built at all (the Windows ROCm torch wheel can't link any C++ extension,
# GPU or CPU variant). Verified end-to-end against an AMD Radeon AI PRO
# R9700 (ROCm 7.2.1): a real mesh rasterizes correctly on the ROCm device
# with zero compiled extensions present.
if (-not $SkipTorchRasterizerFallback) {
    Write-Step "Installing pure-PyTorch custom_rasterizer fallback (texture generation on any GPU path)"
    $vendorSrc = Join-Path $PSScriptRoot "vendor\torch_rasterizer.py"
    $vendorDst = Join-Path $InstallDir "hy3dgen\texgen\torch_rasterizer_vendor"
    if (Test-Path $vendorSrc) {
        New-Item -ItemType Directory -Force -Path $vendorDst | Out-Null
        Copy-Item -Path $vendorSrc -Destination (Join-Path $vendorDst "torch_rasterizer.py") -Force

        $rasterizerPatch = Join-Path $PSScriptRoot "vendor\torch-rasterizer-fallback.patch"
        Push-Location $InstallDir
        try {
            git apply --check $rasterizerPatch | Out-Null
            if ($LASTEXITCODE -eq 0) {
                git apply $rasterizerPatch
                Write-Host "    Patched mesh_render.py to fall back to the pure-PyTorch rasterizer when custom_rasterizer isn't importable."
            } else {
                git apply --reverse --check $rasterizerPatch | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    mesh_render.py already patched, skipping."
                } else {
                    Write-Warn2 "mesh_render.py patch didn't apply cleanly (upstream file may have changed) - apply it manually or diff by hand: $rasterizerPatch"
                }
            }
        } finally {
            Pop-Location
        }
    } else {
        Write-Warn2 "Vendored torch_rasterizer.py not found at $vendorSrc - skipping the pure-PyTorch fallback."
    }
} else {
    Write-Host "`n==> Skipping pure-PyTorch custom_rasterizer fallback (-SkipTorchRasterizerFallback)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
if (-not $SkipModelDownload) {
    Write-Step "Downloading model weights ($ModelRepo)"
    if ($ModelCacheDir) {
        $env:HF_HOME = $ModelCacheDir
        Write-Host "    Caching into $ModelCacheDir (HF_HOME) - set HF_HOME to the same path in your own shell later so from_pretrained() reuses it."
    } else {
        Write-Host "    This pulls into the standard HuggingFace cache (%USERPROFILE%\.cache\huggingface), so from_pretrained() later reuses it without re-downloading. Pass -ModelCacheDir to redirect it (e.g. to another drive)."
    }
    # pip-system-certs makes Python trust the Windows certificate store (not
    # just its bundled certifi list). Without it, huggingface_hub's HTTPS
    # calls fail with "CERTIFICATE_VERIFY_FAILED: unable to get local issuer
    # certificate" on any machine where antivirus/firewall software (Norton,
    # etc.) intercepts HTTPS with its own locally-trusted root cert - Windows
    # trusts it, Python's bundled cert list doesn't.
    & $VenvPython -m pip install pip-system-certs | Out-Null
    try {
        & $VenvPython -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='$ModelRepo')"
    } catch {
        Write-Warn2 "Model download failed: $_"
        Write-Warn2 "If this is a certificate error, pip-system-certs (installed above) should fix it - try re-running this step alone. Otherwise re-run later with:"
        Write-Warn2 "  `"$VenvPython`" -c `"from huggingface_hub import snapshot_download; snapshot_download(repo_id='$ModelRepo')`""
    }
} else {
    Write-Host "`n==> Skipping model download (-SkipModelDownload)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
Write-Step "Done"
Write-Host @"
    Installed to: $InstallDir
    Venv python:  $VenvPython
    GPU path:     $ResolvedVendor
    Model:        $ModelRepo (cached in $(if ($ModelCacheDir) { $ModelCacheDir } else { '%USERPROFILE%\.cache\huggingface' }))

    Try shape generation:
      $(if ($ModelCacheDir) { "`$env:HF_HOME = `"$ModelCacheDir`"`n      " })& "$VenvPython" -c "from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline; p = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained('$ModelRepo'); p(image='assets/demo.png')[0].export('out.glb')"
      (run from $InstallDir so the relative asset path resolves$(if ($ModelCacheDir) { "; set HF_HOME as shown so it finds the cache" }))

    Or launch the Gradio demo (shape + texture both work on every GPU path -
    texture runs via the pure-PyTorch fallback where the native extension
    isn't built, slower but functional):
      cd "$InstallDir"
      & "$VenvPython" gradio_app.py --model_path $ModelRepo --subfolder hunyuan3d-dit-v2-0 --texgen_model_path $ModelRepo --low_vram_mode

    VRAM: ~6 GB for shape generation only, ~16 GB for shape + texture combined.
$(if ($ResolvedVendor -eq "Amd") {
"
    AMD/ROCm notes:
      - Texture generation works via the pure-PyTorch rasterizer fallback
        (verified end-to-end on a Radeon AI PRO R9700) - slower than a
        native CUDA build, but no separate setup needed.
      - Make sure the 26.2.2+ Adrenalin driver is installed.
      - Verify PyTorch sees the GPU: & `"$VenvPython`" -c `"import torch; print(torch.cuda.is_available())`""
} elseif (-not $TextureExtBuilt) {
"
    The native custom_rasterizer build was skipped, but texture generation
    still works via the pure-PyTorch fallback (slower than native CUDA).
    Install MSVC Build Tools + a matching CUDA Toolkit and re-run this
    script with only the build step enabled (see warnings above) for the
    faster native path."
})
"@
