#requires -Version 5.1
<#
.SYNOPSIS
    Benchmarks an LLM via Ollama and/or Unsloth/Hugging Face.

.DESCRIPTION
    Thin PowerShell wrapper around bench_model.py that:

      - locates a Python interpreter (Unsloth Studio's venv first, then a
        plain `python` on PATH),
      - forwards all arguments to the Python script, and
      - writes JSON + Markdown reports to a chosen output directory.

.EXAMPLE
    PS> .\run_benchmark.ps1 -Backend ollama -Model llama3.1:8b -NumPredict 128 -Repeat 3

.EXAMPLE
    PS> .\run_benchmark.ps1 -Backend both -Model unsloth/llama-3.1-8b-bnb-4bit `
        -PythonExe "E:\UnslothStudio\venv\Scripts\python.exe"
#>
[CmdletBinding()]
param(
    [ValidateSet("ollama", "unsloth", "both")]
    [string]$Backend = "ollama",

    [Parameter(Mandatory = $true)]
    [string]$Model,

    [string]$Prompt,
    [string]$PromptFile,
    [string]$Host = "http://127.0.0.1:11434",
    [int]$NumPredict = 128,
    [int]$NumCtx = 2048,
    [int]$Warmup = 1,
    [int]$Repeat = 3,

    [string]$PythonExe,
    [string]$OutputDir = (Join-Path (Get-Location) "benchmark-out")
)

$ErrorActionPreference = "Stop"

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq "Core") {
    throw "This script targets Windows PowerShell or PowerShell on Windows."
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

function Resolve-Python {
    param([string]$Override)
    if ($Override) {
        if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) {
            throw "Python interpreter '$Override' not found."
        }
        return (Resolve-Path -LiteralPath $Override).Path
    }

    $candidates = @()
    # Prefer the Unsloth Studio venv shipped by install_unsloth_windows_amd.ps1
    foreach ($root in @("E:\UnslothStudio", "C:\UnslothStudio")) {
        $candidates += (Join-Path $root "venv\Scripts\python.exe")
        $candidates += (Join-Path $root "Scripts\python.exe")
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    throw "No Python interpreter found. Pass -PythonExe explicitly."
}

$py = Resolve-Python -Override $PythonExe
Write-Host "Using Python: $py" -ForegroundColor Cyan

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$benchScript = Join-Path $scriptDir "bench_model.py"
if (-not (Test-Path -LiteralPath $benchScript -PathType Leaf)) {
    throw "bench_model.py not found next to run_benchmark.ps1 ($scriptDir)."
}

$argList = @()
if ($Prompt)      { $argList += @("--prompt", $Prompt) }
if ($PromptFile)  { $argList += @("--prompt-file", $PromptFile) }
$argList += @(
    "--backend", $Backend,
    "--model", $Model,
    "--host", $Host,
    "--n-predict", $NumPredict,
    "--n-ctx", $NumCtx,
    "--warmup", $Warmup,
    "--repeat", $Repeat,
    "--json-out", (Join-Path $OutputDir "benchmark_results.json"),
    "--md-out",   (Join-Path $OutputDir "benchmark_results.md")
)

Write-Host "Running: $py $benchScript $($argList -join ' ')" -ForegroundColor Cyan
& $py $benchScript @argList
exit $LASTEXITCODE