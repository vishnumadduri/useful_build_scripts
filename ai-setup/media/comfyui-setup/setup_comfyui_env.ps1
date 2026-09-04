#requires -Version 5.1
<#
Sets up ComfyUI (https://github.com/comfyanonymous/ComfyUI) on Windows:
clones the repo, creates a Python venv, installs PyTorch (NVIDIA CUDA, AMD
ROCm-on-Windows preview, or CPU - auto-detected from the GPU present),
installs ComfyUI's requirements, installs ComfyUI-Manager (custom node
manager / model browser) into custom_nodes, sets up joenorton's
comfyui-mcp-server (standalone MCP server that drives a running ComfyUI
instance) in its own sibling venv, and pre-downloads a default checkpoint so
ComfyUI has something to generate with out of the box.

GPU paths mirror hunyuan3d2-setup/setup_hunyuan3d2_env.ps1 in this repo:
  - NVIDIA: CUDA wheel from the official PyTorch index.
  - AMD (e.g. Radeon AI PRO R9700 / RDNA4, gfx1201): AMD's official Windows
    ROCm preview wheels (repo.radeon.com), Python 3.12-only, so this script
    provisions Python 3.12 specifically on that path. Needs the 26.2.2+
    Adrenalin driver installed separately.
  - No GPU detected: CPU-only PyTorch (works, but very slow).

Five modes, picked with -Action:
  - Install (default): clone ComfyUI/ComfyUI-Manager/comfyui-mcp-server into
    -InstallDir/-McpDir (skipping any that are already cloned there) and set
    everything up from scratch.
  - Update: git-pull ComfyUI/ComfyUI-Manager/comfyui-mcp-server already
    installed at -InstallDir/-McpDir to their latest version and reinstall
    their requirements. Fails with a clear error if -InstallDir isn't an
    existing ComfyUI checkout yet - run -Action Install there first.
  - Start: launch ComfyUI (background process, logs to
    <InstallDir>\comfyui.log) on -ComfyPort (auto-picks the next free port
    starting there if it's already taken by something else - e.g. another
    ComfyUI install - and reuses it as-is if that "something else" is
    already-running ComfyUI), then launches comfyui-mcp-server (fixed port
    9000, logs to <McpDir>\mcp-server.log) pointed at whichever port ComfyUI
    ended up on. Both are left running after the script exits; re-running
    -Action Start is safe/idempotent - already-running instances are
    detected and reused rather than double-launched.
  - ListNodes: print the small catalog of ComfyUI custom node packs this
    script knows how to install (currently: Hunyuan3D-2).
  - InstallNode: install one node pack from that catalog (-Node <key>) into
    -InstallDir's custom_nodes, plus any pack-specific extras - for
    Hunyuan3D2, that's the precompiled texture-generation wheel on NVIDIA,
    and copying its example workflows into ComfyUI's workflow sidebar.

Run from an elevated PowerShell prompt (winget installs generally want one).
#>

[CmdletBinding()]
param(
    [ValidateSet("Install", "Update", "Start", "ListNodes", "InstallNode")]
    [string]$Action = "Install",

    [string]$InstallDir,

    [string]$McpDir,

    # -Action InstallNode only. Key from the catalog printed by
    # -Action ListNodes (currently just "Hunyuan3D2").
    [string]$Node,

    # -Action InstallNode only. Skip installing the precompiled
    # custom_rasterizer wheel (texture generation) on the NVIDIA path.
    [switch]$SkipTextureWheel,

    # -Action Start only. Starting port to try for ComfyUI - if already
    # bound by something that isn't a live ComfyUI instance, the next port
    # is tried (up to +20) until a free one is found.
    [int]$ComfyPort = 8188,

    [ValidateSet("Auto", "Nvidia", "Amd", "Cpu")]
    [string]$GpuVendor = "Auto",

    [ValidateSet("cu118", "cu121", "cu124", "cu126", "cu128")]
    [string]$CudaVersion = "cu124",

    [string]$RocmVersion = "7.2.1",

    # "repo_id|filename|models-subfolder" entries, downloaded via
    # huggingface_hub into <InstallDir>\models\<subfolder>. Default gives a
    # working checkpoint out of the box; pass your own list to replace it, or
    # -SkipModelDownload to skip entirely and add models later via
    # ComfyUI-Manager's model downloader UI.
    [string[]]$Models = @(
        "Comfy-Org/stable-diffusion-v1-5-archive|v1-5-pruned-emaonly-fp16.safetensors|checkpoints"
    ),

    [switch]$SkipGitInstall,
    [switch]$SkipPythonInstall,
    [switch]$SkipRepoClone,
    [switch]$SkipVenv,
    [switch]$SkipTorchInstall,
    [switch]$SkipRequirements,
    [switch]$SkipManager,
    [switch]$SkipMcpServer,
    [switch]$SkipModelDownload
)

$ErrorActionPreference = "Stop"
$ComfyRepoUrl = "https://github.com/comfyanonymous/ComfyUI.git"
$ManagerRepoUrl = "https://github.com/ltdrdata/ComfyUI-Manager.git"
$McpRepoUrl = "https://github.com/joenorton/comfyui-mcp-server.git"

if (-not $InstallDir) {
    $defaultInstallDir = "$HOME\ComfyUI"
    $promptLabel = switch ($Action) {
        "Update"      { "ComfyUI directory to update" }
        "Start"       { "ComfyUI directory to start" }
        "ListNodes"   { "ComfyUI directory" }
        "InstallNode" { "ComfyUI directory to install the node pack into" }
        default       { "Install directory for ComfyUI" }
    }
    $response = Read-Host "$promptLabel [$defaultInstallDir]"
    $InstallDir = if ([string]::IsNullOrWhiteSpace($response)) { $defaultInstallDir } else { $response }
}

if (-not $McpDir) {
    $McpDir = "$HOME\comfyui-mcp-server"
}

if ($Action -eq "Update" -and -not (Test-Path (Join-Path $InstallDir ".git"))) {
    Write-Error "-Action Update was passed but $InstallDir is not an existing ComfyUI checkout. Run with -Action Install (the default) first, or point -InstallDir at your existing install."
}

$VenvDir = Join-Path $InstallDir "venv"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$ManagerDir = Join-Path $InstallDir "custom_nodes\ComfyUI-Manager"
$McpVenvDir = Join-Path $McpDir "venv"
$McpVenvPython = Join-Path $McpVenvDir "Scripts\python.exe"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Warn2 {
    param([string]$Message)
    Write-Host "    [!] $Message" -ForegroundColor Yellow
}

function Test-HttpUp {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
        return $true
    } catch {
        # A non-2xx/3xx HTTP response (e.g. 404/406 from an endpoint that
        # doesn't exist/doesn't like GET) still proves something is
        # listening and answering HTTP - only a connection-level failure
        # (refused/timeout) means "nothing there".
        return $null -ne $_.Exception.Response
    }
}

function Test-PortListening {
    param([Parameter(Mandatory)][int]$Port)
    return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

# Distinguishes "this port is already serving *this* -InstallDir's ComfyUI"
# (safe to reuse) from "this port answers HTTP but it's some other ComfyUI
# install, or an unrelated service" (must not reuse - e.g. a second,
# separately-installed ComfyUI already running on the default 8188).
# Two things that look like they'd work here don't:
#   - system_stats' argv: main.py is launched with a relative path
#     (cwd = -InstallDir), so it never contains the full install path.
#   - the OS process's executable path: on Python 3.12+, a venv's
#     Scripts\python.exe is a tiny launcher stub that re-execs the *base*
#     interpreter as a child - the process actually bound to the port always
#     reports the base install's python.exe path, never the venv's.
# So main.py is launched with its *absolute* path (below) specifically so
# the install dir shows up in that child process's own command line, which
# this checks instead.
function Test-ThisComfyUiRunning {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$ExpectedInstallDir)
    if (-not (Test-HttpUp "http://127.0.0.1:$Port/system_stats")) {
        return $false
    }
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) {
        return $false
    }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($conn.OwningProcess)" -ErrorAction SilentlyContinue
    return $proc -and $proc.CommandLine -like "*$ExpectedInstallDir*"
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
    # No stderr redirect: under $ErrorActionPreference = "Stop", a redirected
    # native-command stderr line becomes a terminating NativeCommandError, so
    # a "not found" message from winget would abort the whole script instead
    # of just meaning "not installed".
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
    # WMI is the authoritative check - it reflects what Windows actually
    # enumerated as display hardware. nvidia-smi.exe existing on PATH is
    # NOT sufficient on its own: some machines have a stray/leftover
    # nvidia-smi.exe (e.g. from a driver installer, or bundled for WSL GPU
    # passthrough) with no real NVIDIA GPU present, where it just fails to
    # run ("insufficient permissions" or similar) rather than being absent.
    $wmiHasNvidia = [bool](Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'NVIDIA' })
    if ($wmiHasNvidia) { return $true }
    if (Test-CommandExists nvidia-smi) {
        # No stderr redirect: under $ErrorActionPreference = "Stop", that
        # turns a failing native command's stderr output into a terminating
        # NativeCommandError instead of the false we want here.
        & nvidia-smi --query-gpu=name --format=csv,noheader | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

function Test-AmdGpu {
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'AMD|Radeon' }
    return [bool]$gpu
}

function Sync-GitRepo {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Label
    )
    if (Test-Path (Join-Path $Dir ".git")) {
        if ($Action -eq "Update") {
            Write-Host "    Updating $Label at $Dir to latest..."
            Push-Location $Dir
            try {
                git pull --ff-only
            } catch {
                Write-Warn2 "$Label git pull failed (local changes / diverged history?): $_"
            } finally {
                Pop-Location
            }
        } else {
            Write-Host "    $Label already present at $Dir, skipping clone (use -Action Update to pull latest)."
        }
    } elseif ($Action -eq "Update") {
        Write-Warn2 "$Label not found at $Dir, skipping update - it was never installed there. Run -Action Install to add it."
    } else {
        Write-Host "    Cloning $Label into $Dir..."
        git clone $Url $Dir
    }
}

# ---------------------------------------------------------------------------
# Catalog of ComfyUI custom node packs this script knows how to install via
# -Action InstallNode -Node <key>. Small and hand-maintained on purpose - see
# -Action ListNodes to print it. Each entry's Install scriptblock receives no
# arguments; it closes over $InstallDir/$VenvPython/$ResolvedVendor etc.
$NodeCatalog = [ordered]@{
    "Hunyuan3D2" = [ordered]@{
        DisplayName = "Hunyuan3D-2 (kijai/ComfyUI-Hunyuan3DWrapper)"
        RepoUrl     = "https://github.com/kijai/ComfyUI-Hunyuan3DWrapper.git"
        FolderName  = "ComfyUI-Hunyuan3DWrapper"
        Description = @"
Image/text -> 3D mesh + texture generation as native ComfyUI nodes. Its
DownloadAndLoad* nodes auto-fetch whichever shape checkpoint you pick from
their dropdown the first time you queue a workflow - Hunyuan3D-2 (standard),
-2-mv (multiview-conditioned), -2-mv-fast, -2-0-fast, -2.1, and mini are all
selectable this way, no separate download step needed per variant.

Shape generation AND texture generation (all variants above) both run on
whatever GPU path this script set up (NVIDIA CUDA, AMD ROCm, or CPU).
Texture generation's final step (UV rasterization/baking) normally needs the
custom_rasterizer C++ extension, which only ships as precompiled CUDA wheels
(Windows, cp312) - no ROCm/HIP build exists anywhere upstream. This script
installs that wheel on NVIDIA, AND always installs a vendored pure-PyTorch
reimplementation of the same rasterizer as a fallback (verified against the
native kernel's C++ logic) - it needs no compiler on any platform and runs
on whatever device the tensors are on, so texture baking works on AMD/ROCm
and CPU too, just slower than the native CUDA build.
"@
    }
}
# ---------------------------------------------------------------------------

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

if ($Action -eq "ListNodes") {
    Write-Step "Available node packs (-Action InstallNode -Node <key>)"
    foreach ($key in $NodeCatalog.Keys) {
        $entry = $NodeCatalog[$key]
        $installedMarker = if (Test-Path (Join-Path $InstallDir "custom_nodes\$($entry.FolderName)")) { " [already installed in $InstallDir]" } else { "" }
        Write-Host "`n  $key - $($entry.DisplayName)$installedMarker" -ForegroundColor Cyan
        Write-Host "  $($entry.RepoUrl)"
        ($entry.Description.Trim() -split "`n") | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host "`nInstall one with: ./setup_comfyui_env.ps1 -Action InstallNode -Node <key> -InstallDir `"$InstallDir`""
    exit 0
}

if ($Action -eq "InstallNode") {
    Write-Step "Installing node pack: $Node"

    if (-not $Node) {
        Write-Error "-Action InstallNode requires -Node <key>. Run -Action ListNodes to see available keys."
    }
    $matchedKey = $NodeCatalog.Keys | Where-Object { $_ -eq $Node } | Select-Object -First 1
    if (-not $matchedKey) {
        Write-Error "Unknown -Node '$Node'. Available: $($NodeCatalog.Keys -join ', ') - run -Action ListNodes for details."
    }
    $entry = $NodeCatalog[$matchedKey]

    if (-not (Test-Path $VenvPython)) {
        Write-Error "No ComfyUI install found at $InstallDir (missing $VenvPython). Run -Action Install first."
    }

    $nodeDir = Join-Path $InstallDir "custom_nodes\$($entry.FolderName)"
    Sync-GitRepo -Url $entry.RepoUrl -Dir $nodeDir -Label $entry.DisplayName

    $nodeRequirements = Join-Path $nodeDir "requirements.txt"
    if (Test-Path $nodeRequirements) {
        Write-Host "    Installing requirements..."
        & $VenvPython -m pip install -r $nodeRequirements
    }

    if ($matchedKey -eq "Hunyuan3D2") {
        $venvPyVersion = & $VenvPython -c "import sys; print('%d.%d' % sys.version_info[:2])"

        if ($ResolvedVendor -eq "Nvidia" -and -not $SkipTextureWheel) {
            if ($venvPyVersion -ne "3.12") {
                Write-Warn2 "ComfyUI's venv is Python $venvPyVersion, but the precompiled custom_rasterizer wheels are cp312-only - texture generation's UV bake step won't be installable. Recreate the venv with Python 3.12 (delete $VenvDir, re-run -Action Install with -GpuVendor Nvidia after installing Python 3.12) if you need texture generation."
            } else {
                Write-Step "Installing custom_rasterizer (texture generation) for NVIDIA"
                # Wheels ship inside the repo itself (wheels\*.whl), pinned to
                # specific torch+CUDA combos. Pick by installed torch's CUDA
                # tag; falls back to the plain (untagged) wheel, which
                # historically has been the most broadly compatible one.
                $torchCuda = & $VenvPython -c "import torch; print(torch.version.cuda or '')"
                $wheelsDir = Join-Path $nodeDir "wheels"
                $wheelMap = @{
                    "12.8" = "custom_rasterizer-0.1.0+torch270.cuda128-cp312-cp312-win_amd64.whl"
                    "12.6" = "custom_rasterizer-0.1.0+torch260.cuda126-cp312-cp312-win_amd64.whl"
                    "13.0" = "custom_rasterizer-0.1.0+torch2100.cuda130-cp312-cp312-win_amd64.whl"
                }
                $chosenWheel = if ($torchCuda -and $wheelMap.ContainsKey($torchCuda)) { $wheelMap[$torchCuda] } else { "custom_rasterizer-0.1-cp312-cp312-win_amd64.whl" }
                $wheelPath = Join-Path $wheelsDir $chosenWheel
                if (Test-Path $wheelPath) {
                    Write-Host "    Installed torch CUDA $torchCuda -> using $chosenWheel"
                    try {
                        & $VenvPython -m pip install $wheelPath
                    } catch {
                        Write-Warn2 "custom_rasterizer wheel install failed: $_"
                        Write-Warn2 "Try a different wheel from $wheelsDir by hand if this one doesn't match your torch/CUDA build exactly."
                    }
                } else {
                    Write-Warn2 "Expected wheel not found at $wheelPath (repo layout may have changed upstream) - install manually from $wheelsDir, matching your torch CUDA version ($torchCuda)."
                }
            }
        } elseif ($ResolvedVendor -eq "Nvidia" -and $SkipTextureWheel) {
            Write-Host "    Skipping custom_rasterizer wheel install (-SkipTextureWheel) - texture generation's UV bake step won't work until it's installed manually."
        }

        # Pure-PyTorch fallback for custom_rasterizer's UV-bake step, applied
        # on every GPU path (not just non-NVIDIA): custom_rasterizer is a
        # compiled CUDA/HIP extension with no ROCm build anywhere upstream,
        # and even on NVIDIA the compiled wheel can fail to match the
        # installed torch/CUDA build exactly. mesh_render.py's raster_mode
        # already tries the native extension first and only falls back on
        # ImportError, so installing this is never a downgrade on NVIDIA -
        # it's a safety net, not a replacement. Verified against a literal
        # transcription of the native kernel's C++ logic; runs on whatever
        # device the tensors are on (CUDA, ROCm, MPS, CPU) since it's just
        # ordinary torch ops - needs no compiler anywhere.
        Write-Step "Installing pure-PyTorch custom_rasterizer fallback (texture generation on any GPU path)"
        $vendorSrc = Join-Path $PSScriptRoot "vendor\torch_rasterizer.py"
        $vendorDst = Join-Path $nodeDir "hy3dgen\texgen\torch_rasterizer_vendor"
        if (Test-Path $vendorSrc) {
            New-Item -ItemType Directory -Force -Path $vendorDst | Out-Null
            Copy-Item -Path $vendorSrc -Destination (Join-Path $vendorDst "torch_rasterizer.py") -Force

            $meshRenderPatch = Join-Path $PSScriptRoot "vendor\hunyuan3d2-torch-rasterizer.patch"
            Push-Location $nodeDir
            try {
                git apply --check $meshRenderPatch | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    git apply $meshRenderPatch
                    Write-Host "    Patched mesh_render.py to fall back to the pure-PyTorch rasterizer when custom_rasterizer isn't importable."
                } else {
                    git apply --reverse --check $meshRenderPatch | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    mesh_render.py already patched, skipping."
                    } else {
                        Write-Warn2 "mesh_render.py patch didn't apply cleanly (upstream file may have changed) - apply it manually or diff by hand: $meshRenderPatch"
                    }
                }
            } finally {
                Pop-Location
            }
        } else {
            Write-Warn2 "Vendored torch_rasterizer.py not found at $vendorSrc - skipping the pure-PyTorch fallback."
        }

        if ($ResolvedVendor -ne "Nvidia") {
            Write-Host "    Texture generation's UV bake step now runs via the pure-PyTorch fallback on $ResolvedVendor (slower than a native CUDA build, but no compiler/toolchain needed). Shape generation (all variants: 2.0, -mv, -mv-fast, -0-fast, 2.1, mini) works fully either way."
        }

        # Surface the wrapper's own example workflows in ComfyUI's sidebar
        # workflow browser (which lists subfolders of user\default\workflows)
        # so there's a working starting point instead of building one from
        # scratch - these are what actually exercise the DownloadAndLoad*
        # nodes that pull the shape/texture models on first queue.
        $exampleSrc = Join-Path $nodeDir "example_workflows"
        if (Test-Path $exampleSrc) {
            $exampleDst = Join-Path $InstallDir "user\default\workflows\Hunyuan3D-2"
            New-Item -ItemType Directory -Force -Path $exampleDst | Out-Null
            Copy-Item -Path (Join-Path $exampleSrc "*") -Destination $exampleDst -Recurse -Force
            Write-Host "    Copied example workflows to user\default\workflows\Hunyuan3D-2 - find them in ComfyUI's Workflows sidebar."
        }
    }

    Write-Step "Done"
    Write-Host @"
    $($entry.DisplayName) installed to: $nodeDir

    Start ComfyUI (./setup_comfyui_env.ps1 -Action Start -InstallDir "$InstallDir"), open the UI,
    and load one of the example workflows from the Workflows sidebar
    (Hunyuan3D-2 folder, if this node pack shipped any) - or build your own
    from its DownloadAndLoad*/Hy3D* nodes. Each DownloadAndLoad* node's
    dropdown lets you pick the shape variant (2.0, -mv, -mv-fast, -0-fast,
    2.1, mini) and fetches it automatically the first time you queue.
"@
    exit 0
}

if ($Action -eq "Start") {
    Write-Step "Starting ComfyUI + comfyui-mcp-server"

    if (-not (Test-Path $VenvPython)) {
        Write-Error "No ComfyUI install found at $InstallDir (missing $VenvPython). Run -Action Install first."
    }

    # Reuse an already-running ComfyUI on the requested port only if it's
    # actually *this* -InstallDir's ComfyUI; a port that's merely occupied
    # (by an unrelated service, or a different/older ComfyUI install - e.g.
    # something already sitting on the default 8188) is skipped in favor of
    # the next free port, so this always ends up launching (or reusing) the
    # install this script was pointed at, never someone else's.
    $resolvedComfyPort = $ComfyPort
    $comfyAlreadyRunning = $false
    for ($i = 0; $i -lt 20; $i++) {
        $candidate = $ComfyPort + $i
        if (Test-ThisComfyUiRunning -Port $candidate -ExpectedInstallDir $InstallDir) {
            $resolvedComfyPort = $candidate
            $comfyAlreadyRunning = $true
            Write-Host "    This ComfyUI install is already running on port $candidate, reusing it (skipping launch)."
            break
        }
        if (-not (Test-PortListening $candidate)) {
            $resolvedComfyPort = $candidate
            if ($candidate -ne $ComfyPort) {
                Write-Warn2 "Port $ComfyPort is in use by something else (a different ComfyUI install? an unrelated service?), using $candidate instead."
            }
            break
        }
    }

    if (-not $comfyAlreadyRunning) {
        $comfyLog = Join-Path $InstallDir "comfyui.log"
        Write-Host "    Launching ComfyUI on port $resolvedComfyPort (log: $comfyLog)..."
        $mainPyPath = Join-Path $InstallDir "main.py"
        Start-Process -FilePath $VenvPython -ArgumentList @($mainPyPath, "--port", $resolvedComfyPort) `
            -WorkingDirectory $InstallDir -WindowStyle Hidden `
            -RedirectStandardOutput $comfyLog -RedirectStandardError "$comfyLog.err" | Out-Null

        Write-Host "    Waiting for ComfyUI to come up..."
        $ready = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 2
            if (Test-HttpUp "http://127.0.0.1:$resolvedComfyPort/system_stats") {
                $ready = $true
                break
            }
        }
        if ($ready) {
            Write-Host "    ComfyUI is up at http://127.0.0.1:$resolvedComfyPort"
        } else {
            Write-Warn2 "ComfyUI didn't answer http://127.0.0.1:$resolvedComfyPort/system_stats within 2 minutes - check $comfyLog for errors."
        }
    }

    if (-not $SkipMcpServer) {
        if (-not (Test-Path $McpVenvPython)) {
            Write-Warn2 "No comfyui-mcp-server install found at $McpDir - skipping. Run -Action Install first, or pass -SkipMcpServer to silence this."
        } elseif (Test-PortListening 9000) {
            Write-Host "    Something is already listening on port 9000 (comfyui-mcp-server's fixed port) - assuming it's already running, not relaunching."
        } else {
            $mcpLog = Join-Path $McpDir "mcp-server.log"
            Write-Host "    Launching comfyui-mcp-server against http://127.0.0.1:$resolvedComfyPort (log: $mcpLog)..."
            $psCommand = "`$env:COMFYUI_URL = 'http://127.0.0.1:$resolvedComfyPort'; & '$McpVenvPython' 'server.py'"
            Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", $psCommand) `
                -WorkingDirectory $McpDir -WindowStyle Hidden `
                -RedirectStandardOutput $mcpLog -RedirectStandardError "$mcpLog.err" | Out-Null

            Start-Sleep -Seconds 3
            if (Test-PortListening 9000) {
                Write-Host "    comfyui-mcp-server is up at http://127.0.0.1:9000/mcp"
            } else {
                Write-Warn2 "comfyui-mcp-server doesn't appear to be listening on port 9000 yet - check $mcpLog for errors (e.g. the mcp<2 pin, see README)."
            }
        }
    } else {
        Write-Host "    Skipping comfyui-mcp-server (-SkipMcpServer)"
    }

    Write-Step "Done"
    Write-Host @"
    ComfyUI:            http://127.0.0.1:$resolvedComfyPort  (log: $(Join-Path $InstallDir 'comfyui.log'))
    comfyui-mcp-server:  http://127.0.0.1:9000/mcp  (log: $(Join-Path $McpDir 'mcp-server.log'))

    Both were started as detached background processes and will keep
    running after this window closes. Find/stop them later with:
       Get-Process python | Where-Object { `$_.Path -like "*$InstallDir*" -or `$_.Path -like "*$McpDir*" } | Stop-Process
"@
    exit 0
}

# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

if (-not (Test-CommandExists winget)) {
    Write-Error "winget was not found. Install 'App Installer' from the Microsoft Store, then re-run this script."
}

Write-Host "    GPU path: $ResolvedVendor $(if ($GpuVendor -eq 'Auto') { '(auto-detected)' } else { '(forced via -GpuVendor)' })"
Write-Host "    Action: $Action"

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
        # Don't redirect py.exe's stderr: under $ErrorActionPreference =
        # "Stop", that turns "3.12 not installed" (reported via stderr + exit
        # code) into a script-ending exception instead of the false we want.
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
    Write-Step "Cloning/updating ComfyUI"
    Sync-GitRepo -Url $ComfyRepoUrl -Dir $InstallDir -Label "ComfyUI"
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
            Write-Warn2 "No supported GPU detected/forced, installing CPU-only PyTorch. Generation will be very slow."
            & $VenvPython -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
        }
    }
} else {
    Write-Host "`n==> Skipping PyTorch install (-SkipTorchInstall)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
if (-not $SkipRequirements) {
    Write-Step "Installing ComfyUI requirements"
    & $VenvPython -m pip install -r (Join-Path $InstallDir "requirements.txt")
} else {
    Write-Host "`n==> Skipping requirements install (-SkipRequirements)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
if (-not $SkipManager) {
    Write-Step "Installing ComfyUI-Manager (custom node manager / model browser)"
    Sync-GitRepo -Url $ManagerRepoUrl -Dir $ManagerDir -Label "ComfyUI-Manager"
    $managerRequirements = Join-Path $ManagerDir "requirements.txt"
    if (Test-Path $managerRequirements) {
        & $VenvPython -m pip install -r $managerRequirements
    }
} else {
    Write-Host "`n==> Skipping ComfyUI-Manager (-SkipManager)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# comfyui-mcp-server (https://github.com/joenorton/comfyui-mcp-server) is a
# standalone MCP server that drives a *running* ComfyUI instance over its
# HTTP/WS API - it isn't a ComfyUI custom node, has no GPU/torch dependency,
# and doesn't need to be inside $InstallDir, so it gets its own small venv at
# $McpDir instead of reusing ComfyUI's.
if (-not $SkipMcpServer) {
    Write-Step "Installing comfyui-mcp-server"
    Sync-GitRepo -Url $McpRepoUrl -Dir $McpDir -Label "comfyui-mcp-server"

    if (-not (Test-Path $McpVenvPython)) {
        Write-Host "    Creating venv at $McpVenvDir..."
        python -m venv $McpVenvDir
    } else {
        Write-Host "    venv already exists at $McpVenvDir, skipping."
    }
    & $McpVenvPython -m pip install --upgrade pip | Out-Null

    $mcpRequirements = Join-Path $McpDir "requirements.txt"
    if (Test-Path $mcpRequirements) {
        & $McpVenvPython -m pip install -r $mcpRequirements
    } else {
        Write-Warn2 "No requirements.txt found in $McpDir - repo layout may have changed upstream."
    }
    # requirements.txt pins only "mcp>=0.9.0", which currently resolves to
    # mcp 2.x - server.py imports mcp.server.fastmcp.FastMCP, which was
    # renamed/restructured in mcp 2.x, so the server crashes at import time
    # (ModuleNotFoundError) until downgraded. Force the last 1.x release.
    & $McpVenvPython -m pip install "mcp<2" | Out-Null
} else {
    Write-Host "`n==> Skipping comfyui-mcp-server (-SkipMcpServer)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
if (-not $SkipModelDownload) {
    Write-Step "Downloading models"
    # pip-system-certs makes Python trust the Windows certificate store (not
    # just its bundled certifi list). Without it, huggingface_hub's HTTPS
    # calls can fail with "CERTIFICATE_VERIFY_FAILED: unable to get local
    # issuer certificate" on machines where antivirus/firewall software
    # intercepts HTTPS with its own locally-trusted root cert.
    & $VenvPython -m pip install --upgrade huggingface_hub pip-system-certs | Out-Null

    foreach ($entry in $Models) {
        $parts = $entry -split '\|'
        if ($parts.Count -ne 3) {
            Write-Warn2 "Skipping malformed -Models entry '$entry' (expected 'repo_id|filename|subfolder')."
            continue
        }
        $repoId, $fileName, $subDir = $parts
        $targetDir = Join-Path $InstallDir "models\$subDir"
        $targetFile = Join-Path $targetDir $fileName
        if (Test-Path $targetFile) {
            Write-Host "    $fileName already present in models\$subDir, skipping."
            continue
        }
        Write-Host "    Downloading $repoId/$fileName -> models\$subDir\ ..."
        try {
            & $VenvPython -c "from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='$repoId', filename='$fileName', local_dir=r'$targetDir')"
        } catch {
            Write-Warn2 "Download of $repoId/$fileName failed: $_"
            Write-Warn2 "Gated/licensed repos need a HF token: `$env:HF_TOKEN = '<token>' before re-running, or download manually into $targetDir"
        }
    }
    Write-Host "    Add more models any time via ComfyUI-Manager's 'Model Manager' tab in the UI, or re-run with -Models 'repo_id|filename|subfolder'."
} else {
    Write-Host "`n==> Skipping model download (-SkipModelDownload)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
Write-Step "Done"
Write-Host @"
    ComfyUI installed to: $InstallDir
    ComfyUI venv python:  $VenvPython
    GPU path:             $ResolvedVendor
    ComfyUI-Manager:      $(if (-not $SkipManager) { $ManagerDir } else { "skipped" })
    comfyui-mcp-server:   $(if (-not $SkipMcpServer) { $McpDir } else { "skipped" })

    1. Start ComfyUI:
       cd "$InstallDir"
       & "$VenvPython" main.py --port 8188

       Open http://127.0.0.1:8188 - ComfyUI-Manager adds a "Manager" button
       in the UI for browsing/installing custom nodes and models.

    2. Start the MCP server (with ComfyUI already running):
       cd "$McpDir"
       & "$McpVenvPython" server.py

       Listens at http://127.0.0.1:9000/mcp - register it in .mcp.json:
       {
         "mcpServers": {
           "comfyui-mcp-server": {
             "type": "streamable-http",
             "url": "http://127.0.0.1:9000/mcp"
           }
         }
       }

    To update everything later (git pull + reinstall requirements):
       ./setup_comfyui_env.ps1 -Action Update -InstallDir "$InstallDir" -McpDir "$McpDir" -SkipModelDownload

$(if ($ResolvedVendor -eq "Amd") {
"
    AMD/ROCm notes:
      - Make sure the 26.2.2+ Adrenalin driver is installed.
      - Verify PyTorch sees the GPU: & `"$VenvPython`" -c `"import torch; print(torch.cuda.is_available())`""
})
"@
