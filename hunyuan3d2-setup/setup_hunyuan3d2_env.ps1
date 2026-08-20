#requires -Version 5.1
<#
Sets up Tencent's Hunyuan3D-2 (image/text -> 3D mesh + texture generation):
https://github.com/Tencent-Hunyuan/Hunyuan3D-2

Clones the repo, creates a Python venv, installs PyTorch (NVIDIA CUDA, AMD
ROCm-on-Windows preview, or CPU - auto-detected from the GPU present),
installs the project's requirements + package, best-effort builds the two
CUDA-only C++ extensions needed for texture generation (custom_rasterizer and
differentiable_renderer), and pre-downloads the model weights from
HuggingFace into the standard HF cache so `from_pretrained(...)` doesn't
re-download them on first run.

GPU paths:
  - NVIDIA: needs cl.exe (MSVC) and nvcc (CUDA Toolkit) to also build the
    texture-generation extensions; the script detects both and skips that
    build with instructions if either is missing, rather than silently
    installing multi-GB toolkits. Shape generation alone does not need them.
  - AMD (e.g. Radeon AI PRO R9700 / RDNA4, gfx1201): uses AMD's official
    Windows ROCm preview wheels (repo.radeon.com), which are Python
    3.12-only, so this script provisions Python 3.12 specifically on that
    path. custom_rasterizer/differentiable_renderer are CUDA-only (nvcc,
    .cu kernels) with no HIP port upstream, so texture generation is not
    expected to work on AMD/Windows yet - the build is skipped unconditionally
    on that path. Shape generation runs fine on ROCm.
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
    [switch]$SkipVenv,
    [switch]$SkipTorchInstall,
    [switch]$SkipRequirements,
    [switch]$SkipCustomRasterizerBuild,
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
        Write-Warn2 "Skipping: custom_rasterizer/differentiable_renderer are CUDA-only (nvcc, raw .cu kernels) with no HIP/ROCm port upstream, so they cannot build against an AMD GPU."
        Write-Warn2 "Shape generation still works over ROCm. Texture generation is not expected to work on AMD/Windows until upstream adds HIP support."
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

    Or launch the Gradio demo:
      cd "$InstallDir"
      & "$VenvPython" gradio_app.py --model_path $ModelRepo --subfolder hunyuan3d-dit-v2-0 --texgen_model_path $ModelRepo --low_vram_mode

    VRAM: ~6 GB for shape generation only, ~16 GB for shape + texture combined.
$(if ($ResolvedVendor -eq "Amd") {
"
    AMD/ROCm notes:
      - Texture generation is not supported on this path (see warnings
        above) - only run shape generation.
      - Make sure the 26.2.2+ Adrenalin driver is installed.
      - Verify PyTorch sees the GPU: & `"$VenvPython`" -c `"import torch; print(torch.cuda.is_available())`""
} elseif (-not $TextureExtBuilt) {
"
    If the extension build was skipped, texture generation will fail until
    you install MSVC Build Tools + a matching CUDA Toolkit and re-run this
    script with only the build step enabled (see warnings above)."
})
"@
