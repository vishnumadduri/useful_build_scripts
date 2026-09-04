#!/usr/bin/env python3
# filepath: ai-setup/benchmark/bench_model.py
"""
bench_model.py - Benchmark LLMs on Ollama and/or Unsloth/Hugging Face.

Measures (when available):
  * Tokens / second (overall and per-phase: prompt eval, decode)
  * Time to first token (TTFT), wall-clock latency
  * VRAM (peak / current) via pynvml or nvidia-smi fallback
  * GPU utilization (%) via nvidia-smi
  * Process / host RSS via psutil
  * Model metadata: parameter size, quantization, context window, sha256 of
    gguf blobs (Ollama) or safetensors index hash (HF), file size on disk

Backends:
  * ollama    - HTTP POST /api/generate, streams tokens; resolves gguf via
                /api/show + Ollama's blob store to compute disk size + sha
  * unsloth   - Loads a HF/unsloth checkpoint via transformers (Unsloth's
                FastLanguageModel when present), runs a single generate() pass
                with manual token-level timing
  * both      - Runs the requested backend against each installed stack when
                the same model identifier is offered by both (Ollama tag vs.
                HF repo)

Outputs are written as JSON and a Markdown summary. The JSON includes raw
samples so downstream tooling can replot distributions.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import platform
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any, Callable, Iterable

# ---------------------------------------------------------------------------
# Optional dependency probing - the benchmark still runs with reduced fidelity
# if psutil / pynvml / requests / transformers are missing.
# ---------------------------------------------------------------------------

def _try_import(name: str) -> Any:
    try:
        return __import__(name)
    except Exception:
        return None


psutil = _try_import("psutil")
requests = _try_import("requests")  # noqa: F841  (kept for future streaming)
pynvml = None
try:
    import pynvml as _pynvml  # type: ignore
    pynvml = _pynvml
except Exception:
    pynvml = None

torch = _try_import("torch")
transformers = _try_import("transformers")

# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class GPUSample:
    timestamp_ms: float
    vram_used_mb: float | None = None
    vram_total_mb: float | None = None
    util_pct: float | None = None


@dataclass
class PhaseTimings:
    ttft_ms: float | None
    prompt_eval_ms: float
    decode_ms: float
    total_ms: float
    prompt_tokens: int
    decode_tokens: int


@dataclass
class BackendResult:
    backend: str
    model: str
    resolved_path: str | None
    parameters_b: float | None
    quantization: str | None
    context_window: int | None
    disk_size_bytes: int | None
    artifact_sha256: str | None
    timings: PhaseTimings
    tokens_per_sec_decode: float
    tokens_per_sec_overall: float
    gpu_peak_vram_mb: float | None
    gpu_total_vram_mb: float | None
    gpu_avg_util_pct: float | None
    host_peak_rss_mb: float | None
    host_avg_rss_mb: float | None
    samples: list[dict[str, Any]] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    ok: bool = True
    error: str | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _now_ms() -> float:
    return time.perf_counter() * 1000.0


def _human_bytes(n: int | None) -> str:
    if n is None:
        return "n/a"
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    f = float(n)
    i = 0
    while f >= 1024 and i < len(units) - 1:
        f /= 1024.0
        i += 1
    return f"{f:.2f} {units[i]}"


def _median(values: Iterable[float]) -> float | None:
    vs = [v for v in values if v is not None]
    return statistics.median(vs) if vs else None


def _sha256_file(path: Path, chunk: int = 1 << 20) -> str | None:
    try:
        h = hashlib.sha256()
        with path.open("rb") as fh:
            for blk in iter(lambda: fh.read(chunk), b""):
                h.update(blk)
        return h.hexdigest()
    except OSError:
        return None


# ---------------------------------------------------------------------------
# System probes
# ---------------------------------------------------------------------------

class GPUMonitor:
    """Background-friendly GPU sampler. Safe no-op when no NV/AMD tooling."""

    def __init__(self) -> None:
        self.samples: list[GPUSample] = []
        self.handle = None
        self.kind = "none"
        if pynvml is not None:
            try:
                pynvml.nvmlInit()
                self.handle = pynvml.nvmlDeviceGetHandleByIndex(0)
                info = pynvml.nvmlDeviceGetMemoryInfo(self.handle)
                self._total_mb = info.total / (1024 * 1024)
                self.kind = "pynvml"
                return
            except Exception:
                self.kind = "none"
        # Fallback to nvidia-smi (covers WSL cases and some AMD setups)
        try:
            out = subprocess.run(
                [
                    "nvidia-smi",
                    "--query-gpu=memory.total",
                    "--format=csv,noheader,nounits",
                ],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            if out.returncode == 0 and out.stdout.strip():
                self._total_mb = float(out.stdout.strip().splitlines()[0])
                self.kind = "nvidia-smi"
                return
        except Exception:
            pass
        self._total_mb = None

    def sample(self) -> GPUSample:
        ts = _now_ms()
        used = None
        util = None
        if self.kind == "pynvml" and self.handle is not None:
            try:
                mem = pynvml.nvmlDeviceGetMemoryInfo(self.handle)
                used = mem.used / (1024 * 1024)
            except Exception:
                used = None
            try:
                util = float(pynvml.nvmlDeviceGetUtilizationRates(self.handle).gpu)
            except Exception:
                util = None
        elif self.kind == "nvidia-smi":
            try:
                out = subprocess.run(
                    [
                        "nvidia-smi",
                        "--query-gpu=memory.used,utilization.gpu",
                        "--format=csv,noheader,nounits",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=2,
                    check=False,
                )
                if out.returncode == 0 and out.stdout.strip():
                    parts = out.stdout.strip().splitlines()[0].split(",")
                    if len(parts) >= 1 and parts[0].strip():
                        used = float(parts[0])
                    if len(parts) >= 2 and parts[1].strip():
                        util = float(parts[1])
            except Exception:
                pass
        sample = GPUSample(
            timestamp_ms=ts,
            vram_used_mb=used,
            vram_total_mb=self._total_mb,
            util_pct=util,
        )
        self.samples.append(sample)
        return sample

    def summary(self) -> tuple[float | None, float | None, float | None]:
        used = [s.vram_used_mb for s in self.samples if s.vram_used_mb is not None]
        utils = [s.util_pct for s in self.samples if s.util_pct is not None]
        return (
            max(used) if used else None,
            self._total_mb,
            statistics.mean(utils) if utils else None,
        )


class RSSMonitor:
    def __init__(self) -> None:
        self.proc = psutil.Process(os.getpid()) if psutil else None
        self.samples: list[float] = []

    def sample(self) -> float | None:
        if not self.proc:
            return None
        try:
            rss = self.proc.memory_info().rss / (1024 * 1024)
        except Exception:
            return None
        self.samples.append(rss)
        return rss

    def summary(self) -> tuple[float | None, float | None]:
        if not self.samples:
            return None, None
        return max(self.samples), statistics.mean(self.samples)


# ---------------------------------------------------------------------------
# Ollama backend
# ---------------------------------------------------------------------------

def ollama_resolve_blob(tag: str, host: str) -> tuple[str | None, int | None, str | None, dict[str, Any]]:
    """Locate the gguf blob for a given Ollama tag and return (path, sha, info dict)."""
    show_req = urllib.request.Request(
        f"{host}/api/show",
        data=json.dumps({"name": tag, "verbose": False}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(show_req, timeout=30) as resp:
            info = json.loads(resp.read().decode() or "{}")
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        return None, None, None, {"_error": f"ollama show failed: {exc}"}

    # /api/show returns either "model_info" with quantization hints and
    # "details" with parameter size, or an empty blob list.
    digest = None
    size = None
    for entry in info.get("model_info", {}).values():
        # Model_info values may carry "*.digest" + "*.size" for the gguf.
        if isinstance(entry, str) and entry.endswith(":sha256-") is False and len(entry) == 64:
            digest = "sha256:" + entry
    blob_digest = info.get("digest") or digest
    if isinstance(info.get("size"), int):
        size = info["size"]

    # Fallback: Ollama stores blobs under $OLLAMA_MODELS/blobs/ with the
    # sha256-<digest> filename. We can stat the blob to derive size.
    models_dir = Path(os.environ.get("OLLAMA_MODELS") or (Path.home() / ".ollama" / "models"))
    blob_path = None
    if blob_digest:
        candidate = models_dir / "blobs" / ("sha256-" + blob_digest.split(":", 1)[-1])
        if candidate.exists():
            blob_path = str(candidate)
            size = candidate.stat().st_size
    sha = None
    if blob_path:
        sha = _sha256_file(Path(blob_path))
    return blob_path, size, sha, info


def run_ollama(
    model: str,
    prompt: str,
    *,
    host: str,
    n_predict: int,
    n_ctx: int,
    warmup: int,
    repeat: int,
    gpu_monitor: GPUMonitor,
    rss_monitor: RSSMonitor,
    think: bool | None = None,
) -> BackendResult:
    """think=None keeps the original raw-completion behavior (no chat template,
    so a reasoning model's default thinking mode never engages). think=True/False
    switches to /api/chat with an explicit "think" flag - required for reasoning
    models like Qwen3.5, which otherwise default to thinking on and can silently
    burn the entire num_predict budget on a hidden <think> block, streaming back
    zero visible characters despite reporting a full eval_count."""
    notes: list[str] = []
    blob_path, size, sha, show_info = ollama_resolve_blob(model, host)
    if blob_path is None:
        notes.append(f"ollama blob not resolved locally; {show_info.get('_error', '')}")

    details = (show_info or {}).get("details") or {}
    parameters_b = None
    if details.get("parameter_size"):
        ps_str = str(details["parameter_size"]).upper().replace("B", "")
        try:
            parameters_b = float(ps_str)
        except ValueError:
            pass
    quantization = details.get("quantization_level")
    context_window = None
    for k, v in (show_info or {}).get("model_info", {}).items():
        if k.endswith(".context_length") and isinstance(v, (int, float)):
            context_window = int(v)
            break

    # Warmup pass - not counted.
    if warmup > 0:
        try:
            urllib.request.urlopen(
                urllib.request.Request(
                    f"{host}/api/generate",
                    data=json.dumps(
                        {
                            "model": model,
                            "prompt": "ping",
                            "stream": False,
                            "options": {"num_predict": 8, "num_ctx": max(512, n_ctx)},
                        }
                    ).encode(),
                    headers={"Content-Type": "application/json"},
                ),
                timeout=120,
            ).read()
        except Exception as exc:
            notes.append(f"warmup failed: {exc}")

    runs: list[PhaseTimings] = []
    generated_text = ""
    use_chat = think is not None
    endpoint = "/api/chat" if use_chat else "/api/generate"
    for i in range(repeat):
        if use_chat:
            body = {
                "model": model,
                "messages": [{"role": "user", "content": prompt}],
                "stream": True,
                "think": think,
                "options": {
                    "num_predict": n_predict,
                    "num_ctx": n_ctx,
                    "cache_prompt": False,
                },
            }
        else:
            body = {
                "model": model,
                "prompt": prompt,
                "stream": True,
                "raw": True,
                "options": {
                    "num_predict": n_predict,
                    "num_ctx": n_ctx,
                    # Disable server-side caching of eval results so each run is real work.
                    "cache_prompt": False,
                },
            }
        req = urllib.request.Request(
            f"{host}{endpoint}",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
        )
        t_start = _now_ms()
        first_token_at: float | None = None
        prompt_eval_ms: float | None = None
        decode_tokens = 0
        prompt_tokens = 0
        chunks: list[dict[str, Any]] = []
        try:
            with urllib.request.urlopen(req, timeout=max(60, n_predict * 2)) as resp:
                for raw in resp:
                    line = raw.decode(errors="replace").strip()
                    if not line:
                        continue
                    try:
                        evt = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    chunks.append(evt)
                    piece = evt.get("message", {}).get("content", "") if use_chat else evt.get("response", "")
                    if piece:
                        if first_token_at is None:
                            first_token_at = _now_ms()
                        decode_tokens += 1
                        generated_text += piece
                    if evt.get("done"):
                        prompt_eval_ms = evt.get("prompt_eval_duration", 0) / 1_000_000.0
                        decode_tokens = max(decode_tokens, evt.get("eval_count", decode_tokens))
                        prompt_tokens = evt.get("prompt_eval_count", prompt_tokens)
                        break
        except (urllib.error.URLError, TimeoutError) as exc:
            return BackendResult(
                backend="ollama",
                model=model,
                resolved_path=blob_path,
                parameters_b=parameters_b,
                quantization=quantization,
                context_window=context_window,
                disk_size_bytes=size,
                artifact_sha256=sha,
                timings=PhaseTimings(None, 0.0, 0.0, 0.0, 0, 0),
                tokens_per_sec_decode=0.0,
                tokens_per_sec_overall=0.0,
                gpu_peak_vram_mb=None,
                gpu_total_vram_mb=None,
                gpu_avg_util_pct=None,
                host_peak_rss_mb=None,
                host_avg_rss_mb=None,
                ok=False,
                error=f"ollama generate failed: {exc}",
            )
        gpu_monitor.sample()
        rss_monitor.sample()
        t_end = _now_ms()
        pe_ms = prompt_eval_ms if prompt_eval_ms is not None else 0.0
        # If the server did not report prompt_eval_count, tokenize locally.
        if prompt_tokens == 0:
            try:
                import transformers  # type: ignore
                tokenizer = getattr(transformers, "AutoTokenizer", None)
                if tokenizer is not None:
                    prompt_tokens = len(tokenizer.from_pretrained("gpt2").encode(prompt))
            except Exception:
                prompt_tokens = max(1, len(prompt.split()))
        runs.append(
            PhaseTimings(
                ttft_ms=(first_token_at - t_start) if first_token_at else None,
                prompt_eval_ms=pe_ms,
                decode_ms=max(0.0, t_end - (first_token_at or t_end)),
                total_ms=t_end - t_start,
                prompt_tokens=prompt_tokens,
                decode_tokens=decode_tokens,
            )
        )

    timings = _aggregate_timings(runs)
    peak_vram, total_vram, avg_util = gpu_monitor.summary()
    peak_rss, avg_rss = rss_monitor.summary()

    decode_tps = (
        timings.decode_tokens / (timings.decode_ms / 1000.0)
        if timings.decode_ms > 0
        else 0.0
    )
    overall_tps = (
        timings.decode_tokens / (timings.total_ms / 1000.0)
        if timings.total_ms > 0
        else 0.0
    )

    return BackendResult(
        backend="ollama",
        model=model,
        resolved_path=blob_path,
        parameters_b=parameters_b,
        quantization=quantization,
        context_window=context_window,
        disk_size_bytes=size,
        artifact_sha256=sha,
        timings=timings,
        tokens_per_sec_decode=decode_tps,
        tokens_per_sec_overall=overall_tps,
        gpu_peak_vram_mb=peak_vram,
        gpu_total_vram_mb=total_vram,
        gpu_avg_util_pct=avg_util,
        host_peak_rss_mb=peak_rss,
        host_avg_rss_mb=avg_rss,
        samples=[
            {
                "run": i + 1,
                "ttft_ms": r.ttft_ms,
                "prompt_eval_ms": r.prompt_eval_ms,
                "decode_ms": r.decode_ms,
                "total_ms": r.total_ms,
                "prompt_tokens": r.prompt_tokens,
                "decode_tokens": r.decode_tokens,
            }
            for i, r in enumerate(runs)
        ],
        notes=notes,
        ok=True,
    )


# ---------------------------------------------------------------------------
# Unsloth Studio backend (remote OpenAI-compatible HTTP API, e.g. a
# desktop/LAN install of Unsloth Studio serving GGUF via its bundled
# llama-server). Distinct from the "unsloth" backend below, which loads a
# HF/unsloth checkpoint locally via transformers.
# ---------------------------------------------------------------------------

def _studio_request(host: str, path: str, token: str | None, *, method: str = "GET", body: dict[str, Any] | None = None, timeout: float = 30):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(
        f"{host}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        headers=headers,
        method=method,
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode() or "{}")


def run_unsloth_studio(
    model: str,
    prompt: str,
    *,
    host: str,
    token: str | None,
    gguf_variant: str | None,
    reasoning_effort: str,
    n_predict: int,
    n_ctx: int,
    warmup: int,
    repeat: int,
    gpu_monitor: GPUMonitor,
    rss_monitor: RSSMonitor,
) -> BackendResult:
    """Benchmarks Unsloth Studio's OpenAI-compatible /v1/chat/completions.

    reasoning_effort caps the model's hidden <think> budget (none/minimal/low/
    medium/high/max on reasoning-capable models). Leaving thinking uncapped can
    make a run spend its entire num_predict budget on invisible reasoning
    tokens and stream back no visible answer at all - see the equivalent
    "think" caveat on the Ollama backend above.
    """
    notes: list[str] = []
    quantization = gguf_variant
    context_window = None
    parameters_b = None

    try:
        status = _studio_request(host, "/v1/status", token, timeout=10)
        already_loaded = model in (status.get("loaded") or [])
        if not already_loaded:
            load_body: dict[str, Any] = {"model_path": model, "max_seq_length": n_ctx}
            if gguf_variant:
                load_body["gguf_variant"] = gguf_variant
            _studio_request(host, "/v1/load", token, method="POST", body=load_body, timeout=300)
            status = _studio_request(host, "/v1/status", token, timeout=10)
        else:
            notes.append(f"reused already-loaded model (context/quant reflect its current load, not --n-ctx={n_ctx})")
        context_window = status.get("context_length") or status.get("native_context_length")
        quantization = status.get("gguf_variant") or quantization
    except Exception as exc:
        notes.append(f"status/load probe failed: {exc}")

    def _once() -> tuple[PhaseTimings, str]:
        body = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": True,
            "max_tokens": n_predict,
            "temperature": 0.2,
            "reasoning_effort": reasoning_effort,
            "stream_options": {"include_usage": True},
        }
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(
            f"{host}/v1/chat/completions",
            data=json.dumps(body).encode(),
            headers=headers,
        )
        t_start = _now_ms()
        first_token_at: float | None = None
        chunk_count = 0
        usage_completion_tokens: int | None = None
        prompt_tokens = 0
        text = ""
        with urllib.request.urlopen(req, timeout=max(60, n_predict * 2)) as resp:
            for raw in resp:
                line = raw.decode(errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[len("data:"):].strip()
                if payload == "[DONE]":
                    break
                try:
                    evt = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                usage = evt.get("usage")
                if usage:
                    usage_completion_tokens = usage.get("completion_tokens", usage_completion_tokens)
                    prompt_tokens = usage.get("prompt_tokens", prompt_tokens)
                choices = evt.get("choices") or []
                if choices:
                    delta = choices[0].get("delta") or {}
                    piece = delta.get("content") or ""
                    if piece:
                        if first_token_at is None:
                            first_token_at = _now_ms()
                        chunk_count += 1
                        text += piece
        t_end = _now_ms()
        # Prefer the server-reported completion_tokens (final usage event); each
        # streamed delta chunk is not guaranteed to be exactly one token.
        decode_tokens = usage_completion_tokens if usage_completion_tokens else chunk_count
        return (
            PhaseTimings(
                ttft_ms=(first_token_at - t_start) if first_token_at else None,
                prompt_eval_ms=max(0.0, (first_token_at or t_end) - t_start),
                decode_ms=max(0.0, t_end - (first_token_at or t_end)),
                total_ms=t_end - t_start,
                prompt_tokens=prompt_tokens,
                decode_tokens=decode_tokens,
            ),
            text,
        )

    if warmup > 0:
        try:
            _once()
        except Exception as exc:
            notes.append(f"warmup failed: {exc}")

    runs: list[PhaseTimings] = []
    for _ in range(repeat):
        gpu_monitor.sample()
        rss_monitor.sample()
        try:
            timing, _text = _once()
            runs.append(timing)
        except (urllib.error.URLError, TimeoutError) as exc:
            return BackendResult(
                backend="unsloth-studio",
                model=model,
                resolved_path=None,
                parameters_b=parameters_b,
                quantization=quantization,
                context_window=context_window,
                disk_size_bytes=None,
                artifact_sha256=None,
                timings=PhaseTimings(None, 0.0, 0.0, 0.0, 0, 0),
                tokens_per_sec_decode=0.0,
                tokens_per_sec_overall=0.0,
                gpu_peak_vram_mb=None,
                gpu_total_vram_mb=None,
                gpu_avg_util_pct=None,
                host_peak_rss_mb=None,
                host_avg_rss_mb=None,
                ok=False,
                error=f"unsloth-studio chat completion failed: {exc}",
            )

    timings = _aggregate_timings(runs)
    peak_vram, total_vram, avg_util = gpu_monitor.summary()
    peak_rss, avg_rss = rss_monitor.summary()

    decode_tps = (
        timings.decode_tokens / (timings.decode_ms / 1000.0)
        if timings.decode_ms > 0
        else 0.0
    )
    overall_tps = (
        timings.decode_tokens / (timings.total_ms / 1000.0)
        if timings.total_ms > 0
        else 0.0
    )

    return BackendResult(
        backend="unsloth-studio",
        model=model,
        resolved_path=None,
        parameters_b=parameters_b,
        quantization=quantization,
        context_window=context_window,
        disk_size_bytes=None,
        artifact_sha256=None,
        timings=timings,
        tokens_per_sec_decode=decode_tps,
        tokens_per_sec_overall=overall_tps,
        gpu_peak_vram_mb=peak_vram,
        gpu_total_vram_mb=total_vram,
        gpu_avg_util_pct=avg_util,
        host_peak_rss_mb=peak_rss,
        host_avg_rss_mb=avg_rss,
        samples=[
            {
                "run": i + 1,
                "ttft_ms": r.ttft_ms,
                "prompt_eval_ms": r.prompt_eval_ms,
                "decode_ms": r.decode_ms,
                "total_ms": r.total_ms,
                "prompt_tokens": r.prompt_tokens,
                "decode_tokens": r.decode_tokens,
            }
            for i, r in enumerate(runs)
        ],
        notes=notes,
        ok=True,
    )


# ---------------------------------------------------------------------------
# Unsloth / transformers backend
# ---------------------------------------------------------------------------

def run_unsloth(
    model: str,
    prompt: str,
    *,
    n_predict: int,
    n_ctx: int,
    warmup: int,
    repeat: int,
    gpu_monitor: GPUMonitor,
    rss_monitor: RSSMonitor,
) -> BackendResult:
    notes: list[str] = []
    if transformers is None or torch is None:
        return BackendResult(
            backend="unsloth",
            model=model,
            resolved_path=None,
            parameters_b=None,
            quantization=None,
            context_window=None,
            disk_size_bytes=None,
            artifact_sha256=None,
            timings=PhaseTimings(None, 0.0, 0.0, 0.0, 0, 0),
            tokens_per_sec_decode=0.0,
            tokens_per_sec_overall=0.0,
            gpu_peak_vram_mb=None,
            gpu_total_vram_mb=None,
            gpu_avg_util_pct=None,
            host_peak_rss_mb=None,
            host_avg_rss_mb=None,
            ok=False,
            error="transformers/torch not importable in this Python environment",
        )

    from transformers import AutoModelForCausalLM, AutoTokenizer  # type: ignore

    load_dtype = torch.float16 if torch.cuda.is_available() else torch.float32
    try:
        tokenizer = AutoTokenizer.from_pretrained(model, trust_remote_code=True)
    except Exception as exc:
        return BackendResult(
            backend="unsloth",
            model=model,
            resolved_path=None,
            parameters_b=None,
            quantization=None,
            context_window=None,
            disk_size_bytes=None,
            artifact_sha256=None,
            timings=PhaseTimings(None, 0.0, 0.0, 0.0, 0, 0),
            tokens_per_sec_decode=0.0,
            tokens_per_sec_overall=0.0,
            gpu_peak_vram_mb=None,
            gpu_total_vram_mb=None,
            gpu_avg_util_pct=None,
            host_peak_rss_mb=None,
            host_avg_rss_mb=None,
            ok=False,
            error=f"tokenizer load failed: {exc}",
        )

    # Prefer Unsloth's optimized loader when present.
    try:
        from unsloth import FastLanguageModel  # type: ignore  # noqa: F401

        model_obj, tokenizer = FastLanguageModel.from_pretrained(
            model_name=model,
            max_seq_length=n_ctx,
            dtype=load_dtype,
            load_in_4bit=False,
        )
        notes.append("loaded via Unsloth FastLanguageModel")
    except Exception:
        try:
            model_obj = AutoModelForCausalLM.from_pretrained(
                model,
                torch_dtype=load_dtype,
                trust_remote_code=True,
                low_cpu_mem_usage=True,
            )
            notes.append("loaded via transformers AutoModelForCausalLM (Unsloth unavailable)")
        except Exception as exc:
            return BackendResult(
                backend="unsloth",
                model=model,
                resolved_path=None,
                parameters_b=None,
                quantization=None,
                context_window=None,
                disk_size_bytes=None,
                artifact_sha256=None,
                timings=PhaseTimings(None, 0.0, 0.0, 0.0, 0, 0),
                tokens_per_sec_decode=0.0,
                tokens_per_sec_overall=0.0,
                gpu_peak_vram_mb=None,
                gpu_total_vram_mb=None,
                gpu_avg_util_pct=None,
                host_peak_rss_mb=None,
                host_avg_rss_mb=None,
                ok=False,
                error=f"model load failed: {exc}",
            )

    if hasattr(model_obj, "config"):
        ctx = getattr(model_obj.config, "max_position_embeddings", None)
        if isinstance(ctx, int):
            n_ctx = min(n_ctx, ctx)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model_obj.to(device)
    model_obj.eval()

    # Pull a representative directory + size for hashing / metadata.
    resolved_path = None
    disk_size = None
    try:
        from huggingface_hub import snapshot_download  # type: ignore

        resolved_path = snapshot_download(model, allow_patterns=["*.safetensors", "*.bin", "*.json"])
        p = Path(resolved_path)
        disk_size = sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    except Exception:
        pass

    quantization = None
    cfg = getattr(model_obj, "config", None)
    if cfg is not None:
        q = getattr(cfg, "quantization_config", None)
        if isinstance(q, dict):
            quantization = q.get("quant_method") or q.get("quantization")
        else:
            quantization = getattr(q, "quant_method", None)
    parameters_b = None
    if cfg is not None:
        params = getattr(cfg, "num_parameters", lambda: None)()
        if callable(params):
            params = params()
        if isinstance(params, int) and params > 0:
            parameters_b = params / 1e9

    inputs = tokenizer(prompt, return_tensors="pt").to(device)
    prompt_tokens = int(inputs["input_ids"].shape[-1])
    if warmup > 0:
        with torch.inference_mode():
            try:
                model_obj.generate(
                    **inputs,
                    max_new_tokens=8,
                    do_sample=False,
                    use_cache=True,
                )
            except Exception as exc:
                notes.append(f"warmup failed: {exc}")

    runs: list[PhaseTimings] = []
    with torch.inference_mode():
        for _ in range(repeat):
            gpu_monitor.sample()
            rss_monitor.sample()
            t_start = _now_ms()
            first_token_at: float | None = None
            decode_tokens = 0
            # Manual token-by-token decode so TTFT is observable without
            # streaming APIs in transformers.
            output_ids: list[int] = []
            try:
                # 1) Prompt prefill - run the model once to get the kv cache.
                outputs = model_obj(
                    **inputs,
                    past_key_values=None,
                    use_cache=True,
                )
                next_token = int(outputs.logits[:, -1].argmax(dim=-1))
                torch.cuda.synchronize() if torch.cuda.is_available() else None
                t_first = _now_ms()
                output_ids.append(next_token)
                decode_tokens = 1
                past = outputs.past_key_values
                next_input = torch.tensor([[next_token]], device=device)
                # 2) Decode loop.
                for _ in range(max(1, n_predict) - 1):
                    out = model_obj(
                        input_ids=next_input,
                        past_key_values=past,
                        use_cache=True,
                    )
                    next_token = int(out.logits[:, -1].argmax(dim=-1))
                    past = out.past_key_values
                    next_input = torch.tensor([[next_token]], device=device)
                    output_ids.append(next_token)
                    decode_tokens += 1
                    gpu_monitor.sample()
                    rss_monitor.sample()
                torch.cuda.synchronize() if torch.cuda.is_available() else None
                t_end = _now_ms()
                first_token_at = t_first
            except Exception as exc:
                return BackendResult(
                    backend="unsloth",
                    model=model,
                    resolved_path=resolved_path,
                    parameters_b=parameters_b,
                    quantization=quantization,
                    context_window=n_ctx,
                    disk_size_bytes=disk_size,
                    artifact_sha256=None,
                    timings=PhaseTimings(None, 0.0, 0.0, 0.0, prompt_tokens, 0),
                    tokens_per_sec_decode=0.0,
                    tokens_per_sec_overall=0.0,
                    gpu_peak_vram_mb=None,
                    gpu_total_vram_mb=None,
                    gpu_avg_util_pct=None,
                    host_peak_rss_mb=None,
                    host_avg_rss_mb=None,
                    ok=False,
                    error=f"generate failed: {exc}",
                )
            runs.append(
                PhaseTimings(
                    ttft_ms=(first_token_at - t_start) if first_token_at else None,
                    prompt_eval_ms=max(0.0, (first_token_at or t_end) - t_start),
                    decode_ms=max(0.0, t_end - (first_token_at or t_end)),
                    total_ms=t_end - t_start,
                    prompt_tokens=prompt_tokens,
                    decode_tokens=decode_tokens,
                )
            )

    timings = _aggregate_timings(runs)
    peak_vram, total_vram, avg_util = gpu_monitor.summary()
    peak_rss, avg_rss = rss_monitor.summary()

    decode_tps = (
        timings.decode_tokens / (timings.decode_ms / 1000.0)
        if timings.decode_ms > 0
        else 0.0
    )
    overall_tps = (
        timings.decode_tokens / (timings.total_ms / 1000.0)
        if timings.total_ms > 0
        else 0.0
    )

    return BackendResult(
        backend="unsloth",
        model=model,
        resolved_path=resolved_path,
        parameters_b=parameters_b,
        quantization=quantization,
        context_window=n_ctx,
        disk_size_bytes=disk_size,
        artifact_sha256=None,
        timings=timings,
        tokens_per_sec_decode=decode_tps,
        tokens_per_sec_overall=overall_tps,
        gpu_peak_vram_mb=peak_vram,
        gpu_total_vram_mb=total_vram,
        gpu_avg_util_pct=avg_util,
        host_peak_rss_mb=peak_rss,
        host_avg_rss_mb=avg_rss,
        samples=[
            {
                "run": i + 1,
                "ttft_ms": r.ttft_ms,
                "prompt_eval_ms": r.prompt_eval_ms,
                "decode_ms": r.decode_ms,
                "total_ms": r.total_ms,
                "prompt_tokens": r.prompt_tokens,
                "decode_tokens": r.decode_tokens,
            }
            for i, r in enumerate(runs)
        ],
        notes=notes,
        ok=True,
    )


# ---------------------------------------------------------------------------
# Aggregation / reporting
# ---------------------------------------------------------------------------

def _aggregate_timings(runs: list[PhaseTimings]) -> PhaseTimings:
    if not runs:
        return PhaseTimings(None, 0.0, 0.0, 0.0, 0, 0)
    return PhaseTimings(
        ttft_ms=_median(r.ttft_ms for r in runs),
        prompt_eval_ms=statistics.median(r.prompt_eval_ms for r in runs),
        decode_ms=statistics.median(r.decode_ms for r in runs),
        total_ms=statistics.median(r.total_ms for r in runs),
        prompt_tokens=int(statistics.median(r.prompt_tokens for r in runs)),
        decode_tokens=int(statistics.median(r.decode_tokens for r in runs)),
    )


def render_markdown(results: list[BackendResult], args: argparse.Namespace) -> str:
    lines: list[str] = []
    lines.append(f"# Model benchmark - {time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")
    lines.append(f"System: {platform.platform()} | Python {platform.python_version()}")
    if torch is not None:
        lines.append(f"torch {torch.__version__} | cuda {torch.cuda.is_available()}")
    if transformers is not None:
        lines.append(f"transformers {transformers.__version__}")
    lines.append("")
    lines.append("## Configuration")
    lines.append("")
    lines.append(f"- Backend: `{args.backend}`")
    lines.append(f"- Model: `{args.model}`")
    lines.append(f"- num_predict: `{args.n_predict}`")
    lines.append(f"- num_ctx: `{args.n_ctx}`")
    lines.append(f"- warmup: `{args.warmup}`")
    lines.append(f"- repeat: `{args.repeat}`")
    if args.prompt_file:
        lines.append(f"- prompt_file: `{args.prompt_file}`")
    if args.prompt:
        lines.append(f"- prompt: `{args.prompt[:120]}{'...' if len(args.prompt) > 120 else ''}`")
    lines.append("")

    lines.append("## Results")
    lines.append("")
    lines.append(
        "| Backend | Model | Params (B) | Quant | Ctx | Disk | tok/s decode | tok/s overall | TTFT (ms) | Peak VRAM (MiB) | Avg GPU util (%) | Peak RSS (MiB) |"
    )
    lines.append(
        "|---|---|---|---|---|---|---|---|---|---|---|---|"
    )
    for r in results:
        if not r.ok:
            lines.append(
                f"| {r.backend} | `{r.model}` | _error_ | - | - | - | - | - | - | - | - | - |"
            )
            continue
        lines.append(
            "| "
            + " | ".join(
                [
                    r.backend,
                    f"`{r.model}`",
                    f"{r.parameters_b:.2f}" if r.parameters_b else "n/a",
                    r.quantization or "n/a",
                    str(r.context_window) if r.context_window else "n/a",
                    _human_bytes(r.disk_size_bytes),
                    f"{r.tokens_per_sec_decode:.2f}",
                    f"{r.tokens_per_sec_overall:.2f}",
                    f"{r.timings.ttft_ms:.1f}" if r.timings.ttft_ms else "n/a",
                    f"{r.gpu_peak_vram_mb:.0f}" if r.gpu_peak_vram_mb else "n/a",
                    f"{r.gpu_avg_util_pct:.1f}" if r.gpu_avg_util_pct else "n/a",
                    f"{r.host_peak_rss_mb:.0f}" if r.host_peak_rss_mb else "n/a",
                ]
            )
            + " |"
        )

    lines.append("")
    lines.append("## Per-run")
    for r in results:
        lines.append("")
        lines.append(f"### {r.backend} - `{r.model}`")
        if not r.ok:
            lines.append("")
            lines.append(f"_failed: {r.error}_")
            continue
        if r.notes:
            for n in r.notes:
                lines.append(f"> {n}")
        if r.resolved_path:
            lines.append(f"- resolved_path: `{r.resolved_path}`")
        if r.artifact_sha256:
            lines.append(f"- sha256: `{r.artifact_sha256}`")
        if r.samples:
            lines.append("")
            lines.append("| run | TTFT (ms) | prompt_eval (ms) | decode (ms) | total (ms) | prompt_tokens | decode_tokens |")
            lines.append("|---|---|---|---|---|---|---|")
            for s in r.samples:
                lines.append(
                    "| {run} | {ttft} | {pe} | {dec} | {tot} | {pt} | {dt} |".format(
                        run=s["run"],
                        ttft=f"{s['ttft_ms']:.1f}" if s["ttft_ms"] else "n/a",
                        pe=f"{s['prompt_eval_ms']:.1f}",
                        dec=f"{s['decode_ms']:.1f}",
                        tot=f"{s['total_ms']:.1f}",
                        pt=s["prompt_tokens"],
                        dt=s["decode_tokens"],
                    )
                )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _load_prompt(args: argparse.Namespace) -> str:
    if args.prompt_file:
        return Path(args.prompt_file).read_text(encoding="utf-8")
    if args.prompt:
        return args.prompt
    # Default deterministic prompt sized to exercise prefill + decode.
    return (
        "You are a senior systems engineer. Explain in 4-6 sentences the trade-offs "
        "between speculative decoding and multi-query attention when serving a 7B "
        "parameter LLM at 200 req/s on a single AMD MI300X.\n\n"
        "Cover: prefill vs decode bottleneck, KV cache reuse, VRAM headroom, and "
        "expected tok/s impact."
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Benchmark LLMs on Ollama and/or Unsloth/Hugging Face.")
    p.add_argument(
        "--backend",
        choices=["ollama", "unsloth", "unsloth-studio", "both"],
        default="ollama",
        help="'unsloth' loads a HF/unsloth checkpoint locally via transformers; "
        "'unsloth-studio' calls a remote Unsloth Studio install's OpenAI-compatible "
        "HTTP API instead; 'both' runs ollama + unsloth (local).",
    )
    p.add_argument("--model", required=True, help="Ollama tag (e.g. llama3.1:8b) or HF/unsloth repo id")
    p.add_argument("--prompt", help="Prompt text")
    p.add_argument("--prompt-file", dest="prompt_file", help="Path to prompt text file")
    p.add_argument("--host", default=os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434"))
    p.add_argument("--n-predict", type=int, default=128, dest="n_predict")
    p.add_argument("--n-ctx", type=int, default=2048, dest="n_ctx")
    p.add_argument("--warmup", type=int, default=1)
    p.add_argument("--repeat", type=int, default=3)
    p.add_argument(
        "--think",
        choices=["default", "true", "false"],
        default="default",
        help="Ollama only. 'default' keeps the raw-completion /api/generate call "
        "(no chat template, thinking never engages). 'true'/'false' switches to "
        "/api/chat with an explicit think flag - use 'false' to get a fair "
        "decode-speed comparison against a reasoning model that would otherwise "
        "spend its whole token budget on hidden <think> output.",
    )
    p.add_argument("--json-out", default="benchmark_results.json", dest="json_out")
    p.add_argument("--md-out", default="benchmark_results.md", dest="md_out")
    p.add_argument(
        "--studio-host",
        default=os.environ.get("UNSLOTH_STUDIO_URL", "http://127.0.0.1:8888"),
        help="unsloth-studio backend only: base URL of the Unsloth Studio install.",
    )
    p.add_argument(
        "--studio-token",
        default=os.environ.get("UNSLOTH_STUDIO_TOKEN"),
        help="unsloth-studio backend only: bearer token/API key (Settings > API Keys in Studio).",
    )
    p.add_argument(
        "--gguf-variant",
        default=None,
        help="unsloth-studio backend only: quant variant to load, e.g. UD-Q4_K_XL.",
    )
    p.add_argument(
        "--reasoning-effort",
        default="medium",
        choices=["none", "minimal", "low", "medium", "high", "max"],
        help="unsloth-studio backend only: caps the model's hidden thinking budget.",
    )
    args = p.parse_args(argv)
    think = {"default": None, "true": True, "false": False}[args.think]

    prompt = _load_prompt(args)

    gpu_monitor = GPUMonitor()
    rss_monitor = RSSMonitor()
    results: list[BackendResult] = []

    def _run(backend: str) -> None:
        if backend == "ollama":
            results.append(
                run_ollama(
                    args.model,
                    prompt,
                    host=args.host,
                    n_predict=args.n_predict,
                    n_ctx=args.n_ctx,
                    warmup=args.warmup,
                    repeat=args.repeat,
                    gpu_monitor=gpu_monitor,
                    rss_monitor=rss_monitor,
                    think=think,
                )
            )
        elif backend == "unsloth-studio":
            results.append(
                run_unsloth_studio(
                    args.model,
                    prompt,
                    host=args.studio_host,
                    token=args.studio_token,
                    gguf_variant=args.gguf_variant,
                    reasoning_effort=args.reasoning_effort,
                    n_predict=args.n_predict,
                    n_ctx=args.n_ctx,
                    warmup=args.warmup,
                    repeat=args.repeat,
                    gpu_monitor=gpu_monitor,
                    rss_monitor=rss_monitor,
                )
            )
        else:
            results.append(
                run_unsloth(
                    args.model,
                    prompt,
                    n_predict=args.n_predict,
                    n_ctx=args.n_ctx,
                    warmup=args.warmup,
                    repeat=args.repeat,
                    gpu_monitor=gpu_monitor,
                    rss_monitor=rss_monitor,
                )
            )

    for backend in (["ollama", "unsloth"] if args.backend == "both" else [args.backend]):
        _run(backend)

    payload = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "config": {
            "backend": args.backend,
            "model": args.model,
            "n_predict": args.n_predict,
            "n_ctx": args.n_ctx,
            "warmup": args.warmup,
            "repeat": args.repeat,
            "host": args.host,
        },
        "results": [asdict(r) for r in results],
    }
    Path(args.json_out).write_text(json.dumps(payload, indent=2), encoding="utf-8")
    Path(args.md_out).write_text(render_markdown(results, args), encoding="utf-8")
    print(f"Wrote {args.json_out} and {args.md_out}")
    for r in results:
        if r.ok:
            print(
                f"[{r.backend}] {r.model}: {r.tokens_per_sec_decode:.2f} tok/s decode, "
                f"{r.tokens_per_sec_overall:.2f} tok/s overall, "
                f"peak VRAM {r.gpu_peak_vram_mb} MiB"
            )
        else:
            print(f"[{r.backend}] {r.model}: FAILED ({r.error})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())