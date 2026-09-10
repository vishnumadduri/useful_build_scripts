# Ollama CUDA 12.2 container

Build the current `main` branch of Ollama as a Linux/AMD64 container with only
CPU and CUDA 12.2 runners. CUDA 13, ROCm, Vulkan, and MLX are excluded.

## Build on Windows

```powershell
.\build-ollama-cuda122.ps1
```

## Build on Linux or WSL

```bash
bash ./build-ollama-cuda12-container.sh
```

Both build scripts clone the upstream repository, apply
[ollama-cuda122.patch](ollama-cuda122.patch), and build its `cuda12-image`
target. The temporary source checkout is removed after a successful or failed
build unless `KeepSource` / `--keep-source` is specified.

Run it with an NVIDIA GPU:

```powershell
docker run --rm --gpus all -p 11434:11434 -v ollama:/root/.ollama ollama:cuda12.2
```

Select an Ollama branch or tag and optionally limit the CUDA architectures:

```powershell
.\build-ollama-cuda122.ps1 -OllamaRef v0.17.7 -CudaArchitectures '86;89'
```

```bash
bash ./build-ollama-cuda12-container.sh \
  --ollama-ref v0.17.7 --cuda-architectures '86;89'
```

CUDA architecture defaults are `61;70;75;80;86;89;90`. The host needs a recent NVIDIA driver and NVIDIA Container Toolkit support.
