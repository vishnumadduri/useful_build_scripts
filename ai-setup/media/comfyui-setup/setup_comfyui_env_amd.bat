@echo off
REM Same as setup_comfyui_env.bat, but forces the AMD/ROCm GPU path
REM (-GpuVendor Amd) so double-clicking this file needs no arguments.
REM Bypasses the PowerShell execution policy for this run only (does not
REM change your system-wide policy). Any extra arguments passed to this
REM .bat are forwarded to the .ps1, e.g.:
REM   setup_comfyui_env_amd.bat -Action Update -InstallDir D:\AI\ComfyUI

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_comfyui_env.ps1" -GpuVendor Amd %*
