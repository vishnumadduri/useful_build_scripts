@echo off
REM filepath: ai-setup/benchmark/run_benchmark.bat
REM Convenience wrapper that invokes the PowerShell runner with ExecutionPolicy Bypass.
REM Usage:
REM   run_benchmark.bat ollama llama3.1:8b 128 3
REM   run_benchmark.bat both  unsloth/llama-3.1-8b-bnb-4bit 128 3

setlocal
set "BACKEND=%~1"
set "MODEL=%~2"
set "NPREDICT=%~3"
set "REPEAT=%~4"

if "%BACKEND%"=="" set "BACKEND=ollama"
if "%MODEL%"==""    set "MODEL=llama3.1:8b"
if "%NPREDICT%"=="" set "NPREDICT=128"
if "%REPEAT%"==""   set "REPEAT=3"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_benchmark.ps1" ^
    -Backend "%BACKEND%" -Model "%MODEL%" -NumPredict %NPREDICT% -Repeat %REPEAT%
set "EXITCODE=%ERRORLEVEL%"
endlocal & exit /b %EXITCODE%