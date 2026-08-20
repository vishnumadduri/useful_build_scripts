@echo off
REM Same as setup_hunyuan3d2_env.bat, but forces the AMD/ROCm GPU path
REM (-GpuVendor Amd) so double-clicking this file needs no arguments.
REM Bypasses the PowerShell execution policy for this run only (does not
REM change your system-wide policy). Any extra arguments passed to this
REM .bat are forwarded to the .ps1, e.g.:
REM   setup_hunyuan3d2_env_amd.bat -ModelRepo tencent/Hunyuan3D-2mini

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_hunyuan3d2_env.ps1" -GpuVendor Amd %*
