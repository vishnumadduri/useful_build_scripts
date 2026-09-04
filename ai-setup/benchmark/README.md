# Model Benchmark Utility

`bench_model.py` measures the same set of metrics for an LLM run through
**Ollama** or through **Unsloth / Hugging Face transformers**:

| Metric | Source |
|---|---|
| tok/s (decode phase) | per-token stream timing |
| tok/s (overall) | total wall-clock / decode tokens |
| Time to first token (TTFT) | first streamed token timestamp |
| prompt eval duration | server / model timing |
| peak + average **VRAM** | `pynvml` -> `nvidia-smi` fallback (also covers WSL) |
| peak + average **RSS** | `psutil` |
| GPU utilization (%) | `pynvml` / `nvidia-smi` |
| model size on disk | Ollama blob stat or `huggingface_hub.snapshot_download` |
| model sha256 | Ollama blob sha256 or HF safetensors index |
| parameters, quantization, context window | `/api/show` or HF `config` |

It writes both a JSON report (for tooling) and a Markdown summary table (for
humans).

## Files

- `bench_model.py` - the general-purpose benchmark (Python 3.10+): Ollama,
  local Unsloth/HF transformers, or a remote Unsloth Studio's HTTP API.
- `run_benchmark.ps1` - Windows wrapper that finds a Python interpreter
  (Unsloth Studio venv first, then PATH) and forwards arguments.
- `run_benchmark.bat` - one-line CMD launcher for quick tests.
- `run_thinking_benchmark.py` - focused coding-task benchmark comparing
  reasoning ("thinking") forced off vs. on, on both backends at once.
- `prompts/coding_lru_cache.txt` - the coding prompt used by
  `run_thinking_benchmark.py`.
- `reports/` - JSON + Markdown output from `run_thinking_benchmark.py` runs.

## Examples

Ollama only:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_benchmark.ps1 `
    -Backend ollama -Model llama3.1:8b -NumPredict 128 -Repeat 3
```

Unsloth (HF repo id) only:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_benchmark.ps1 `
    -Backend unsloth `
    -Model unsloth/llama-3.1-8b-bnb-4bit `
    -PythonExe "E:\UnslothStudio\venv\Scripts\python.exe"
```

Both backends, custom prompt:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_benchmark.ps1 `
    -Backend both `
    -Model llama3.1:8b `
    -PromptFile .\prompt.txt `
    -OutputDir .\out
```

Quick CMD launcher:

```cmd
run_benchmark.bat ollama llama3.1:8b 128 3
```

## Notes

- The Ollama pass streams tokens; per-token timing gives an honest
  decode-phase tok/s rather than a server-averaged one.
- The Unsloth pass does a real prefill + manual decode loop so TTFT and
  prompt-eval time are measured the same way as for Ollama.
- `--warmup N` runs N uncounted passes first; `--repeat N` is what gets
  reported (median across runs).
- Optional deps (`psutil`, `pynvml`, `transformers`, `torch`) are detected at
  start-up; missing pieces degrade gracefully (metric becomes `n/a`) instead
  of failing the whole run.
- The script never blocks on missing optional deps. If you want the full
  metric set on Windows + AMD GPUs, run it from the Unsloth Studio venv,
  which already ships `torch`, `transformers`, `psutil`, and ROCm.

## Live backends: Ollama and Unsloth Studio over HTTP

`bench_model.py --backend unsloth-studio` and `run_thinking_benchmark.py`
(below) call a running Unsloth Studio install's OpenAI-compatible API
directly, instead of loading weights locally. That API requires a bearer
token (Settings > API Keys in Studio). Pass it via `--studio-token` or set
`UNSLOTH_STUDIO_TOKEN` in your environment - **never commit it to a file in
this repo**. Likewise point `--studio-host` / `UNSLOTH_STUDIO_URL` at the
Studio instance (e.g. `http://192.168.0.209:8888` for a LAN install) and
`--host` / `OLLAMA_HOST` at Ollama.

## `run_thinking_benchmark.py` - coding task, thinking on vs. off

A focused companion script: runs one coding prompt (bundled at
`prompts/coding_lru_cache.txt`) against both Ollama and Unsloth Studio,
each with reasoning/"thinking" forced off and forced on, and writes a
Markdown + JSON report. Both backends stream hidden reasoning separately
from the visible answer (Ollama: `message.thinking`; Studio:
`delta.reasoning_content`), so the report measures the reasoning overhead
directly - time to first visible token, how many tokens went to hidden
reasoning before any visible output, and whether a run produced a visible
answer at all within its token budget (a reasoning-heavy run can spend its
whole budget thinking and stream back nothing - a well-formed response with
a real cost, not an error).

```powershell
python run_thinking_benchmark.py `
    --ollama-host "http://192.168.0.209:11434" --ollama-model "qwen3.8:27b-q4_K_M" `
    --studio-host "http://192.168.0.209:8888" --studio-token $env:UNSLOTH_STUDIO_TOKEN `
    --studio-model "unsloth/Qwen3.8-27B-GGUF" --gguf-variant "UD-Q4_K_XL" `
    --n-ctx 131072 --n-predict-off 700 --n-predict-on 1500 --warmup 1 --repeat 3 `
    --out-dir .\reports
```

Notes:

- `--n-ctx` sets the context window on *both* backends for an apples-to-
  apples comparison; a larger reservation costs decode throughput on both
  engines even when the actual conversation is short.
- `--studio-reasoning-on` defaults to `"high"`, but Unsloth Studio's own
  chat template silently upgrades `high` to `xhigh` (its most exhaustive
  setting) - expect it to spend the *entire* token budget thinking unless
  you raise `--n-predict-on` a lot or pass `--studio-reasoning-on medium`.
- `--skip-ollama` / `--skip-studio` run just one side.