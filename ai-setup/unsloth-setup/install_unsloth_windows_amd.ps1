#requires -Version 5.1
<#
.SYNOPSIS
    Installs Unsloth Studio for Windows, defaulting to E:\UnslothStudio.

.DESCRIPTION
    This is a small Windows-first wrapper around Unsloth's official installer.
    It sets UNSLOTH_STUDIO_HOME only for the installer process, so Unsloth and
    its virtual environment are created under -InstallDir instead of C:.

    The official installer detects supported AMD/ROCm hardware and selects the
    matching AMD PyTorch wheels automatically. It falls back to CPU PyTorch if
    the installed AMD GPU is not supported by its ROCm wheel set.
#>
[CmdletBinding()]
param(
    [ValidateSet("Install", "Update")]
    [string]$Action = "Install",

    # Change this to any drive/path with sufficient free space.
    [string]$InstallDir = "E:\UnslothStudio",

    # Hugging Face model/cache root. Defaults inside -InstallDir.
    [string]$ModelCacheDir,

    # Install without opening Unsloth Studio when setup completes.
    [switch]$SkipAutoStart
)

$ErrorActionPreference = "Stop"

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq "Core") {
    throw "This installer is for Windows. Run it in Windows PowerShell or PowerShell on Windows."
}

$resolvedInstallDir = [Environment]::ExpandEnvironmentVariables($InstallDir)
try {
    $resolvedInstallDir = [System.IO.Path]::GetFullPath($resolvedInstallDir)
} catch {
    throw "Invalid install path '$InstallDir': $($_.Exception.Message)"
}

$root = [System.IO.Path]::GetPathRoot($resolvedInstallDir)
if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "The drive for '$resolvedInstallDir' is unavailable. Connect/mount it, or pass -InstallDir with a valid path."
}

New-Item -ItemType Directory -Path $resolvedInstallDir -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($ModelCacheDir)) {
    $ModelCacheDir = Join-Path $resolvedInstallDir "huggingface"
}
try {
    $resolvedModelCacheDir = [System.IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables($ModelCacheDir)
    )
} catch {
    throw "Invalid model-cache path '$ModelCacheDir': $($_.Exception.Message)"
}
$modelHubCacheDir = Join-Path $resolvedModelCacheDir "hub"
New-Item -ItemType Directory -Path $modelHubCacheDir -Force | Out-Null

$previousStudioHome = $env:UNSLOTH_STUDIO_HOME
$hadPreviousStudioHome = $null -ne $previousStudioHome
$previousSkipAutoStart = $env:UNSLOTH_SKIP_AUTOSTART
$hadPreviousSkipAutoStart = $null -ne $previousSkipAutoStart
$previousHfHome = $env:HF_HOME
$hadPreviousHfHome = $null -ne $previousHfHome
$previousHfHubCache = $env:HF_HUB_CACHE
$hadPreviousHfHubCache = $null -ne $previousHfHubCache

function New-UnslothStartLauncher {
    param(
        [Parameter(Mandatory)][string]$StudioHome,
        [Parameter(Mandatory)][string]$HfHome,
        [Parameter(Mandatory)][string]$HfHubCache
    )

    $launcherPath = Join-Path $StudioHome "start.bat"
    $content = @"
@echo off
setlocal
set "UNSLOTH_STUDIO_HOME=$StudioHome"
set "HF_HOME=$HfHome"
set "HF_HUB_CACHE=$HfHubCache"
call "%~dp0bin\unsloth.cmd" studio -p 8888
set "UNSLOTH_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %UNSLOTH_EXIT_CODE%
"@
    [System.IO.File]::WriteAllText(
        $launcherPath,
        $content,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Write-Host "Created launcher: $launcherPath" -ForegroundColor Cyan
}

try {
    # The official installer reads this environment variable before choosing
    # its install directory. This changes only the current PowerShell process.
    $env:UNSLOTH_STUDIO_HOME = $resolvedInstallDir
    # Persist these for future PowerShell/Unsloth launches. huggingface_hub
    # reads them at import time; HF_HUB_CACHE is where model repos live.
    [Environment]::SetEnvironmentVariable("HF_HOME", $resolvedModelCacheDir, "User")
    [Environment]::SetEnvironmentVariable("HF_HUB_CACHE", $modelHubCacheDir, "User")
    $env:HF_HOME = $resolvedModelCacheDir
    $env:HF_HUB_CACHE = $modelHubCacheDir
    if ($SkipAutoStart) {
        $env:UNSLOTH_SKIP_AUTOSTART = "1"
    }

    if ($Action -eq "Update") {
        $unslothLauncher = Join-Path $resolvedInstallDir "bin\unsloth.cmd"
        if (-not (Test-Path -LiteralPath $unslothLauncher -PathType Leaf)) {
            throw "No Unsloth installation launcher was found at '$unslothLauncher'. Run with -Action Install first, or pass the correct -InstallDir."
        }

        Write-Host "Checking Unsloth Studio for updates..." -ForegroundColor Cyan
        & $unslothLauncher studio update
        if ($LASTEXITCODE -ne 0) {
            throw "Unsloth Studio update failed (exit code $LASTEXITCODE). Close any running Unsloth Studio windows and try again."
        }
        New-UnslothStartLauncher -StudioHome $resolvedInstallDir -HfHome $resolvedModelCacheDir -HfHubCache $modelHubCacheDir
        Write-Host "Unsloth Studio is up to date." -ForegroundColor Green
    } else {
        Write-Host "Installing Unsloth Studio for Windows to: $resolvedInstallDir" -ForegroundColor Cyan
        Write-Host "Hugging Face models will be cached in: $modelHubCacheDir" -ForegroundColor Cyan
        Write-Host "AMD/ROCm support is detected and configured by Unsloth's official installer." -ForegroundColor Cyan

        $installer = Invoke-RestMethod -Uri "https://unsloth.ai/install.ps1"
        Invoke-Expression $installer
        New-UnslothStartLauncher -StudioHome $resolvedInstallDir -HfHome $resolvedModelCacheDir -HfHubCache $modelHubCacheDir
    }
} finally {
    if ($hadPreviousStudioHome) {
        $env:UNSLOTH_STUDIO_HOME = $previousStudioHome
    } else {
        Remove-Item Env:UNSLOTH_STUDIO_HOME -ErrorAction SilentlyContinue
    }

    if ($hadPreviousSkipAutoStart) {
        $env:UNSLOTH_SKIP_AUTOSTART = $previousSkipAutoStart
    } else {
        Remove-Item Env:UNSLOTH_SKIP_AUTOSTART -ErrorAction SilentlyContinue
    }

    if ($hadPreviousHfHome) {
        $env:HF_HOME = $previousHfHome
    } else {
        Remove-Item Env:HF_HOME -ErrorAction SilentlyContinue
    }
    if ($hadPreviousHfHubCache) {
        $env:HF_HUB_CACHE = $previousHfHubCache
    } else {
        Remove-Item Env:HF_HUB_CACHE -ErrorAction SilentlyContinue
    }
}
