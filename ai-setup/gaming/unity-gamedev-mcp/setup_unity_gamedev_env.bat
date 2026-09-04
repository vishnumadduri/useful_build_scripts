@echo off
REM Launches setup_unity_gamedev_env.ps1 with the execution policy bypassed
REM for this run only (does not change your system-wide PowerShell policy).
REM Any arguments passed to this .bat are forwarded to the .ps1, e.g.:
REM   setup_unity_gamedev_env.bat -ProjectName SpaceShooter -SkipEditorInstall

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_unity_gamedev_env.ps1" %*
