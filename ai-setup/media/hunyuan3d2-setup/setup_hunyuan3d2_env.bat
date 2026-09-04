@echo off
REM Launches setup_hunyuan3d2_env.ps1 with the execution policy bypassed
REM for this run only (does not change your system-wide PowerShell policy).
REM Any arguments passed to this .bat are forwarded to the .ps1, e.g.:
REM   setup_hunyuan3d2_env.bat -ModelRepo tencent/Hunyuan3D-2mini

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_hunyuan3d2_env.ps1" %*
