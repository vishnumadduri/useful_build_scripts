#requires -Version 5.1
<#
.SYNOPSIS
    Windows launcher for installing Unsloth Core for AMD GPUs in WSL.

.DESCRIPTION
    Unsloth's AMD installation guide is a Linux/WSL procedure. This launcher
    runs its companion Bash script in Ubuntu-24.04 and keeps the environment
    on E: by default (visible to WSL as /mnt/e/UnslothAMD).
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "E:\UnslothAMD",
    [string]$Distro = "Ubuntu-24.04",
    [string]$RocmIndexUrl = "https://download.pytorch.org/whl/rocm7.0"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "WSL is unavailable. In an elevated PowerShell window run: wsl --install -d $Distro; then reboot and run this script again."
}

$installedDistros = @(wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($installedDistros -notcontains $Distro) {
    Write-Host "Installing WSL distribution $Distro..." -ForegroundColor Cyan
    wsl.exe --install -d $Distro
    if ($LASTEXITCODE -ne 0) {
        throw "WSL distribution installation failed (exit code $LASTEXITCODE)."
    }
    Write-Host "Restart Windows, finish Ubuntu's first-run username/password setup, then run this script again." -ForegroundColor Yellow
    exit 0
}

$resolvedInstallDir = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($InstallDir))
$drive = [System.IO.Path]::GetPathRoot($resolvedInstallDir).TrimEnd('\', '/')
if ($drive -notmatch '^[A-Za-z]:$' -or -not (Test-Path -LiteralPath "$drive\" -PathType Container)) {
    throw "-InstallDir must be on an available Windows drive, for example E:\UnslothAMD. Received: $resolvedInstallDir"
}

$linuxInstallDir = "/mnt/$($drive.Substring(0, 1).ToLower())/$($resolvedInstallDir.Substring(3).Replace('\', '/'))"
$scriptDrive = $PSScriptRoot.Substring(0, 1).ToLower()
$scriptRelativePath = $PSScriptRoot.Substring(3).Replace('\', '/')
$linuxScript = "/mnt/$scriptDrive/$scriptRelativePath/install_unsloth_amd.sh"

Write-Host "Installing Unsloth AMD environment in WSL at: $linuxInstallDir" -ForegroundColor Cyan
& wsl.exe -d $Distro -- bash $linuxScript --install-dir $linuxInstallDir --rocm-index-url $RocmIndexUrl
if ($LASTEXITCODE -ne 0) {
    throw "The WSL Unsloth AMD installer failed (exit code $LASTEXITCODE)."
}
