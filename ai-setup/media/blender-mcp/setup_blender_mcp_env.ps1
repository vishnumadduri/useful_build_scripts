#requires -Version 5.1
<#
Installs Blender and `uv`, downloads the BlenderMCP addon
(https://github.com/ahujasid/blender-mcp), and registers the `blender-mcp`
MCP server (run via `uvx blender-mcp`) with Claude Code.

BlenderMCP has two halves that both need to be in place:
  1. A Blender addon (addon.py) that runs a small socket server *inside*
     Blender, listening on localhost:9876. Installing/enabling it, and
     clicking "Connect to Claude" each time Blender opens, is interactive
     and cannot be scripted.
  2. An MCP server (`uvx blender-mcp`) that Claude Code/Claude Desktop talk
     to over stdio, which relays to that socket. This script wires that half
     up automatically.

Run from an elevated PowerShell prompt (winget installs generally want one).
#>

[CmdletBinding()]
param(
    [switch]$SkipBlenderInstall,
    [switch]$SkipUvInstall,
    [switch]$SkipAddonDownload,
    [switch]$SkipMcpRegister
)

$ErrorActionPreference = "Stop"
$AddonDir = Join-Path $HOME ".blender-mcp"
$AddonPath = Join-Path $AddonDir "addon.py"
$AddonUrl = "https://raw.githubusercontent.com/ahujasid/blender-mcp/main/addon.py"

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

function Find-BlenderExe {
    $candidates = @(
        "$env:ProgramFiles\Blender Foundation\*\blender.exe",
        "${env:ProgramFiles(x86)}\Blender Foundation\*\blender.exe"
    )
    foreach ($pattern in $candidates) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Blender*' } |
        Select-Object -First 1

    if ($entry -and $entry.InstallLocation) {
        $exe = Join-Path $entry.InstallLocation "blender.exe"
        if (Test-Path $exe) { return $exe }
    }

    return $null
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$FriendlyName
    )
    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null | Select-String -SimpleMatch $Id
    if ($installed) {
        Write-Host "    $FriendlyName already installed, skipping."
        return
    }
    Write-Host "    Installing $FriendlyName ($Id) via winget..."
    # --source winget avoids winget aborting the whole search when its msstore
    # source is unreachable/misconfigured (seen as a TLS cert-validation error),
    # even though the package is only ever published to the winget source.
    winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements --source winget
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "winget reported a non-zero exit code for $FriendlyName. It may already be installed under a different source, or need a manual install."
    }
}

# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

if (-not (Test-CommandExists winget)) {
    Write-Error "winget was not found. Install 'App Installer' from the Microsoft Store, then re-run this script."
}

# ---------------------------------------------------------------------------
if (-not $SkipBlenderInstall) {
    Write-Step "Installing Blender"
    Install-WingetPackage -Id "BlenderFoundation.Blender" -FriendlyName "Blender"
} else {
    Write-Host "`n==> Skipping Blender install (-SkipBlenderInstall)" -ForegroundColor Cyan
}

$BlenderExe = Find-BlenderExe
if ($BlenderExe) {
    Write-Host "    Found Blender at: $BlenderExe"
} else {
    Write-Warn2 "Could not locate blender.exe (checked default paths and the registry). It may need a new shell/registry refresh after install."
}

# ---------------------------------------------------------------------------
# `uv`/`uvx` is how the blender-mcp server is normally run (`uvx blender-mcp`)
# without a separate pip install/venv step.
if (-not $SkipUvInstall) {
    Write-Step "Installing uv (provides uvx)"
    Install-WingetPackage -Id "astral-sh.uv" -FriendlyName "uv"
} else {
    Write-Host "`n==> Skipping uv install (-SkipUvInstall)" -ForegroundColor Cyan
}

if (-not (Test-CommandExists uvx)) {
    Write-Warn2 "'uvx' not on PATH yet - often needs a new shell after install."
}

# ---------------------------------------------------------------------------
# The addon only needs to be downloaded to disk here; installing it into
# Blender ("Install from Disk" in Preferences > Add-ons) and enabling it is
# an interactive step done inside the Blender UI.
if (-not $SkipAddonDownload) {
    Write-Step "Downloading the BlenderMCP addon"
    New-Item -ItemType Directory -Force -Path $AddonDir | Out-Null
    try {
        Invoke-WebRequest -Uri $AddonUrl -OutFile $AddonPath -UseBasicParsing
        Write-Host "    Saved addon to: $AddonPath"
    } catch {
        Write-Warn2 "Failed to download addon.py: $_"
        Write-Warn2 "Download it manually from $AddonUrl and save it somewhere Blender's 'Install from Disk' dialog can reach."
    }
} else {
    Write-Host "`n==> Skipping addon download (-SkipAddonDownload)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
if (-not $SkipMcpRegister) {
    Write-Step "Registering blender-mcp with Claude Code"
    if (Test-CommandExists claude) {
        try {
            claude mcp remove blender-mcp --scope user 2>$null | Out-Null
        } catch {}
        try {
            # --system-certs: uv's bundled cert bundle can fail with
            # "invalid peer certificate: UnknownIssuer" behind TLS-inspecting
            # proxies/networks (the same class of issue winget's msstore
            # source hits above) - trusting the OS cert store avoids it.
            claude mcp add --scope user blender-mcp -- uvx --system-certs blender-mcp
            Write-Host "    Registered. Verify with: claude mcp list"
        } catch {
            Write-Warn2 "claude mcp add failed: $_"
        }
    } else {
        Write-Warn2 "'claude' CLI not found on PATH - install Claude Code, then run:"
        Write-Warn2 "  claude mcp add --scope user blender-mcp -- uvx --system-certs blender-mcp"
    }
} else {
    Write-Host "`n==> Skipping Claude Code MCP registration (-SkipMcpRegister)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
Write-Step "Done. Manual steps still required"
Write-Host @"
    1. Open Blender.
    2. Edit > Preferences > Add-ons > (top-right dropdown) Install from Disk...
       select: $AddonPath
    3. Enable the checkbox next to "Interface: Blender MCP".
    4. In the 3D viewport, open the sidebar (press N) and select the
       "BlenderMCP" tab. Click "Connect to Claude" - this starts the socket
       server on localhost:9876 that the MCP server relays to. You need to
       click this again each time you restart Blender.
    5. In Claude Code, run 'claude mcp list' to confirm 'blender-mcp' is
       registered, then start a new conversation and ask it to work with
       Blender - the first tool call will launch 'uvx blender-mcp' on demand.

    Optional (configured inside the Blender addon panel, not by this script):
      - Poly Haven: enable "Use assets from Poly Haven" for free HDRIs/models/textures.
      - Hyper3D Rodin: add an API key for AI-generated 3D models.
      - Sketchfab: add an API key/token to search and import Sketchfab models.

    Troubleshooting:
      - "Could not connect to Blender" - make sure Blender is open and you
        clicked "Connect to Claude" in the BlenderMCP sidebar tab for this
        session; the socket server does not survive a Blender restart.
      - 'uvx' not found - open a new terminal so PATH picks up the winget
        install, or install uv manually: https://docs.astral.sh/uv/getting-started/installation/
"@
