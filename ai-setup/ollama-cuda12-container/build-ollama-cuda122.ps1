[CmdletBinding()]
param(
    [string] $ImageTag = 'ollama:cuda12.2',
    [string] $OllamaRef = 'main',
    [string] $CudaArchitectures = '61;70;75;80;86;89;90',
    [switch] $NoCache,
    [switch] $KeepSource
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$patchFile = Join-Path $scriptDir 'ollama-cuda122.patch'

if (-not (Test-Path -LiteralPath $patchFile -PathType Leaf)) {
    throw "Upstream Dockerfile patch was not found: $patchFile"
}

try {
    & docker version --format '{{.Server.Version}}' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker daemon is unavailable.'
    }
} catch {
    throw 'Docker Desktop is not running. Start it, then run this script again.'
}

$previousBuildKit = $env:DOCKER_BUILDKIT
$env:DOCKER_BUILDKIT = '1'
$sourceDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("ollama-cuda122-" + [guid]::NewGuid().ToString('N'))

try {
    # Match GitHub's LF Dockerfile so the checked-in unified patch applies even
    # when the host's global Git configuration enables core.autocrlf.
    & git -c core.autocrlf=false -c core.eol=lf clone --depth 1 --branch $OllamaRef https://github.com/ollama/ollama.git $sourceDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Could not download Ollama ref '$OllamaRef'."
    }

    & git -C $sourceDirectory apply --check --unidiff-zero $patchFile
    if ($LASTEXITCODE -ne 0) {
        throw 'The upstream Dockerfile changed and the CUDA 12.2 patch no longer applies.'
    }
    & git -C $sourceDirectory apply --unidiff-zero $patchFile
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not apply the CUDA 12.2 Dockerfile patch.'
    }

    $arguments = @('build', '--pull', '--target', 'cuda12-image', '--tag', $ImageTag, '--build-arg', "CUDA_ARCHITECTURES=$CudaArchitectures", $sourceDirectory)
    if ($NoCache) {
        $arguments = @('build', '--pull', '--no-cache', '--target', 'cuda12-image', '--tag', $ImageTag, '--build-arg', "CUDA_ARCHITECTURES=$CudaArchitectures", $sourceDirectory)
    }
    & docker @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker build failed with exit code $LASTEXITCODE."
    }
} finally {
    $env:DOCKER_BUILDKIT = $previousBuildKit
    if (-not $KeepSource -and (Test-Path -LiteralPath $sourceDirectory)) {
        Remove-Item -LiteralPath $sourceDirectory -Recurse -Force
    }
}

if ($KeepSource) {
    Write-Host "Source checkout retained at $sourceDirectory"
}

Write-Host "Built $ImageTag"
Write-Host "Run: docker run --rm --gpus all -p 11434:11434 -v ollama:/root/.ollama $ImageTag"
