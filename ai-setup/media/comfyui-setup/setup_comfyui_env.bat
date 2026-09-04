@echo off
REM Launches setup_comfyui_env.ps1 with the execution policy bypassed
REM for this run only (does not change your system-wide PowerShell policy).
REM Any arguments passed to this .bat are forwarded to the .ps1, e.g.:
REM   setup_comfyui_env.bat -Action Install -InstallDir D:\AI\ComfyUI
REM   setup_comfyui_env.bat -Action Update -InstallDir D:\AI\ComfyUI
REM   setup_comfyui_env.bat -Action Start -InstallDir D:\AI\ComfyUI

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_comfyui_env.ps1" %*
