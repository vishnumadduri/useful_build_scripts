#!/usr/bin/env python3
# filepath: ai-setup/benchmark/run_thinking_benchmark.py
"""
run_thinking_benchmark.py - Coding-task benchmark across Ollama and Unsloth
Studio, each backend run twice: once with reasoning ("thinking") forced off,
once forced on. Both backends stream hidden reasoning and the visible answer
as separate fields (Ollama: message.thinking vs message.content; Unsloth
Studio: delta.reasoning_content vs delta.content), so this script measures
the reasoning overhead directly instead of just noting that it exists:

  * time to first reasoning token vs time to first VISIBLE token
  * how many tokens / how much wall time went to hidden reasoning before any
    visible output appeared
  * whether the run produced a visible answer at all within the token budget
    (a reasoning-heavy run can spend its entire budget thinking and stream
    back nothing - a well-formed response with a real cost, not an error)

This is a focused companion to bench_model.py, not a replacement for it - it
skips GPU/RSS instrumentation to stay simple, and always uses the chat
(message-based) endpoints on both backends so the thinking/content split is
observable, which bench_model.py does not expose.

Outputs a JSON report (raw + aggregated) and a Markdown report next to it.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_PROMPT_FILE = SCRIPT_DIR / "prompts" / "coding_lru_cache.txt"


def _now_ms() -> float:
    return time.perf_counter() * 1000.0


def _median(values: list[float | int | None]) -> float | None:
    vs = [v for v in values if v is not None]
    return statistics.median(vs) if vs else None


# ---------------------------------------------------------------------------
# Per-run result
# ---------------------------------------------------------------------------

@dataclass
class RunResult:
    ok: bool
    error: str | None = None
    ttft_thinking_ms: float | None = None
    ttft_content_ms: float | None = None
    thinking_ms: float | None = None
    content_decode_ms: float = 0.0
    total_ms: float = 0.0
    thinking_tokens: int = 0
    content_tokens: int = 0
    total_tokens_reported: int | None = None
    prompt_tokens: int = 0
    visible_chars: int = 0
    reached_visible_answer: bool = False


# ---------------------------------------------------------------------------
# Ollama
# ---------------------------------------------------------------------------

def stream_ollama(host: str, model: str, prompt: str, *, think: bool, n_predict: int, n_ctx: int) -> RunResult:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "think": think,
        "options": {"num_predict": n_predict, "num_ctx": n_ctx, "cache_prompt": False},
    }
    req = urllib.request.Request(
        f"{host}/api/chat",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    t_start = _now_ms()
    first_thinking_at: float | None = None
    first_content_at: float | None = None
    thinking_tokens = 0
    content_tokens = 0
    content_chars = 0
    eval_count: int | None = None
    prompt_eval_count = 0
    try:
        with urllib.request.urlopen(req, timeout=max(120, n_predict * 3)) as resp:
            for raw in resp:
                line = raw.decode(errors="replace").strip()
                if not line:
                    continue
                try:
                    evt = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg = evt.get("message") or {}
                think_piece = msg.get("thinking") or ""
                content_piece = msg.get("content") or ""
                if think_piece:
                    if first_thinking_at is None:
                        first_thinking_at = _now_ms()
                    thinking_tokens += 1
                if content_piece:
                    if first_content_at is None:
                        first_content_at = _now_ms()
                    content_tokens += 1
                    content_chars += len(content_piece)
                if evt.get("done"):
                    eval_count = evt.get("eval_count")
                    prompt_eval_count = evt.get("prompt_eval_count", 0)
                    break
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return RunResult(ok=False, error=f"ollama request failed: {exc}")

    t_end = _now_ms()
    # eval_count (server-reported, includes both thinking + content tokens) is
    # authoritative; counting non-empty streamed deltas undercounts by ~15-20%
    # in practice (some real tokens arrive as empty-string pieces mid-stream),
    # so derive the content-token count from it rather than trusting the raw
    # per-chunk count directly.
    if eval_count is not None:
        content_tokens = max(content_tokens, eval_count - thinking_tokens)
    return RunResult(
        ok=True,
        ttft_thinking_ms=(first_thinking_at - t_start) if first_thinking_at else None,
        ttft_content_ms=(first_content_at - t_start) if first_content_at else None,
        thinking_ms=(first_content_at - first_thinking_at) if (first_thinking_at and first_content_at) else None,
        content_decode_ms=max(0.0, t_end - first_content_at) if first_content_at else 0.0,
        total_ms=t_end - t_start,
        thinking_tokens=thinking_tokens,
        content_tokens=content_tokens,
        total_tokens_reported=eval_count,
        prompt_tokens=prompt_eval_count,
        visible_chars=content_chars,
        reached_visible_answer=content_chars > 0,
    )


def ollama_warmup(host: str, model: str, n_ctx: int) -> str | None:
    try:
        urllib.request.urlopen(
            urllib.request.Request(
                f"{host}/api/generate",
                data=json.dumps(
                    {"model": model, "prompt": "ping", "stream": False, "options": {"num_predict": 8, "num_ctx": n_ctx}}
                ).encode(),
                headers={"Content-Type": "application/json"},
            ),
            timeout=max(120, n_ctx // 100),
        ).read()
        return None
    except Exception as exc:  # noqa: BLE001
        return str(exc)


# ---------------------------------------------------------------------------
# Unsloth Studio
# ---------------------------------------------------------------------------

def _studio_request(host: str, path: str, token: str | None, *, method: str = "GET", body: dict[str, Any] | None = None, timeout: float = 30) -> dict[str, Any]:
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


def ensure_studio_loaded(host: str, token: str | None, model: str, gguf_variant: str | None, n_ctx: int) -> str | None:
    """Loads the model if it isn't already resident. Returns an error string, or None on success."""
    try:
        status = _studio_request(host, "/v1/status", token, timeout=10)
        if model in (status.get("loaded") or []):
            return None
        load_body: dict[str, Any] = {"model_path": model, "max_seq_length": n_ctx}
        if gguf_variant:
            load_body["gguf_variant"] = gguf_variant
        _studio_request(host, "/v1/load", token, method="POST", body=load_body, timeout=600)
        return None
    except Exception as exc:  # noqa: BLE001
        return str(exc)


def stream_studio(host: str, token: str | None, model: str, prompt: str, *, reasoning_effort: str, n_predict: int) -> RunResult:
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
    first_thinking_at: float | None = None
    first_content_at: float | None = None
    thinking_tokens = 0
    content_tokens = 0
    content_chars = 0
    prompt_tokens = 0
    usage_completion_tokens: int | None = None
    try:
        with urllib.request.urlopen(req, timeout=max(120, n_predict * 3)) as resp:
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
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}
                think_piece = delta.get("reasoning_content") or ""
                content_piece = delta.get("content") or ""
                if think_piece:
                    if first_thinking_at is None:
                        first_thinking_at = _now_ms()
                    thinking_tokens += 1
                if content_piece:
                    if first_content_at is None:
                        first_content_at = _now_ms()
                    content_tokens += 1
                    content_chars += len(content_piece)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return RunResult(ok=False, error=f"unsloth-studio request failed: {exc}")

    t_end = _now_ms()
    # See the matching comment in stream_ollama: trust the server-reported
    # completion_tokens total over the raw per-chunk count.
    if usage_completion_tokens is not None:
        content_tokens = max(content_tokens, usage_completion_tokens - thinking_tokens)
    return RunResult(
        ok=True,
        ttft_thinking_ms=(first_thinking_at - t_start) if first_thinking_at else None,
        ttft_content_ms=(first_content_at - t_start) if first_content_at else None,
        thinking_ms=(first_content_at - first_thinking_at) if (first_thinking_at and first_content_at) else None,
        content_decode_ms=max(0.0, t_end - first_content_at) if first_content_at else 0.0,
        total_ms=t_end - t_start,
        thinking_tokens=thinking_tokens,
        content_tokens=content_tokens,
        total_tokens_reported=usage_completion_tokens,
        prompt_tokens=prompt_tokens,
        visible_chars=content_chars,
        reached_visible_answer=content_chars > 0,
    )


# ---------------------------------------------------------------------------
# Condition runner
# ---------------------------------------------------------------------------

@dataclass
class ConditionSummary:
    backend: str
    thinking: bool
    label: str
    n_predict: int
    n_ctx: int
    runs: list[dict[str, Any]] = field(default_factory=list)
    median_ttft_content_ms: float | None = None
    median_thinking_ms: float | None = None
    median_thinking_tokens: float | None = None
    median_content_tokens: float | None = None
    median_content_tok_s: float | None = None
    median_total_ms: float | None = None
    visible_answer_rate: float = 0.0
    notes: list[str] = field(default_factory=list)
    ok: bool = True
    error: str | None = None


def run_condition(backend: str, thinking: bool, label: str, n_predict: int, n_ctx: int, warmup: int, repeat: int, call_fn) -> ConditionSummary:
    notes: list[str] = []
    for _ in range(warmup):
        r = call_fn()
        if not r.ok:
            notes.append(f"warmup failed: {r.error}")

    results: list[RunResult] = []
    for i in range(repeat):
        r = call_fn()
        if not r.ok:
            return ConditionSummary(
                backend=backend, thinking=thinking, label=label, n_predict=n_predict, n_ctx=n_ctx,
                notes=notes, ok=False, error=r.error,
            )
        results.append(r)

    content_tps = [
        r.content_tokens / (r.content_decode_ms / 1000.0)
        for r in results if r.content_decode_ms > 0 and r.content_tokens
    ]
    visible_rate = sum(1 for r in results if r.reached_visible_answer) / len(results)

    return ConditionSummary(
        backend=backend,
        thinking=thinking,
        label=label,
        n_predict=n_predict,
        n_ctx=n_ctx,
        runs=[asdict(r) for r in results],
        median_ttft_content_ms=_median([r.ttft_content_ms for r in results]),
        median_thinking_ms=_median([r.thinking_ms for r in results]),
        median_thinking_tokens=_median([r.thinking_tokens for r in results]),
        median_content_tokens=_median([r.content_tokens for r in results]),
        median_content_tok_s=_median(content_tps) if content_tps else None,
        median_total_ms=_median([r.total_ms for r in results]),
        visible_answer_rate=visible_rate,
        notes=notes,
        ok=True,
    )


# ---------------------------------------------------------------------------
# Report rendering
# ---------------------------------------------------------------------------

def render_markdown(conditions: list[ConditionSummary], args: argparse.Namespace) -> str:
    lines: list[str] = []
    lines.append(f"# Coding-task benchmark: thinking on vs. off - {time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")
    lines.append(f"Prompt: `{args.prompt_file}` &middot; context: `{args.n_ctx}` tokens &middot; "
                  f"warmup={args.warmup}, repeat={args.repeat}")
    lines.append("")
    lines.append("## Results")
    lines.append("")
    lines.append("| Backend | Thinking | TTFT (visible) | Thinking latency | Thinking tok | Content tok/s | Wall time | Visible answer rate |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for c in conditions:
        if not c.ok:
            lines.append(f"| {c.backend} | {'on' if c.thinking else 'off'} | _error_ | - | - | - | - | `{c.error}` |")
            continue
        lines.append(
            "| "
            + " | ".join(
                [
                    c.backend,
                    "on" if c.thinking else "off",
                    f"{c.median_ttft_content_ms:.0f} ms" if c.median_ttft_content_ms is not None else "never",
                    f"{c.median_thinking_ms:.0f} ms" if c.median_thinking_ms is not None else "n/a",
                    f"{c.median_thinking_tokens:.0f}" if c.median_thinking_tokens is not None else "0",
                    f"{c.median_content_tok_s:.1f}" if c.median_content_tok_s is not None else "n/a",
                    f"{c.median_total_ms / 1000.0:.1f} s" if c.median_total_ms is not None else "n/a",
                    f"{c.visible_answer_rate * 100:.0f}%",
                ]
            )
            + " |"
        )

    lines.append("")
    lines.append("## Notes")
    lines.append("")
    for c in conditions:
        if not c.ok:
            lines.append(f"- **{c.backend} / thinking={'on' if c.thinking else 'off'}** failed: {c.error}")
            continue
        if c.thinking:
            if c.visible_answer_rate < 1.0:
                lines.append(
                    f"- **{c.backend} / thinking on**: {(1 - c.visible_answer_rate) * 100:.0f}% of runs never "
                    f"produced a visible answer within {c.n_predict} tokens - the whole budget went to hidden "
                    f"reasoning ({c.median_thinking_tokens:.0f} reasoning tokens median)."
                )
            elif c.median_thinking_ms is not None:
                lines.append(
                    f"- **{c.backend} / thinking on**: median {c.median_thinking_ms:.0f} ms "
                    f"({c.median_thinking_tokens:.0f} tokens) of hidden reasoning before the visible answer started."
                )
        for n in c.notes:
            lines.append(f"  - {n}")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Coding-task benchmark: Ollama and Unsloth Studio, each with thinking forced off and on."
    )
    p.add_argument("--prompt-file", default=str(DEFAULT_PROMPT_FILE), dest="prompt_file")
    p.add_argument("--n-ctx", type=int, default=131072, dest="n_ctx", help="Context window, both backends (default: 128k).")
    p.add_argument("--n-predict-off", type=int, default=700, dest="n_predict_off", help="Token budget with thinking off.")
    p.add_argument("--n-predict-on", type=int, default=1500, dest="n_predict_on", help="Token budget with thinking on.")
    p.add_argument("--warmup", type=int, default=1)
    p.add_argument("--repeat", type=int, default=3)

    p.add_argument("--skip-ollama", action="store_true")
    p.add_argument("--ollama-host", default=os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434"))
    p.add_argument("--ollama-model", default="qwen3.8:27b-q4_K_M")

    p.add_argument("--skip-studio", action="store_true")
    p.add_argument("--studio-host", default=os.environ.get("UNSLOTH_STUDIO_URL", "http://127.0.0.1:8888"))
    p.add_argument("--studio-token", default=os.environ.get("UNSLOTH_STUDIO_TOKEN"))
    p.add_argument("--studio-model", default="unsloth/Qwen3.8-27B-GGUF")
    p.add_argument("--gguf-variant", default="UD-Q4_K_XL")
    p.add_argument("--studio-reasoning-off", default="none", help="reasoning_effort used for the 'thinking off' condition.")
    p.add_argument("--studio-reasoning-on", default="high", help="reasoning_effort used for the 'thinking on' condition.")

    p.add_argument("--out-dir", default=".", dest="out_dir")
    p.add_argument("--json-out", default="coding_thinking_report.json", dest="json_out")
    p.add_argument("--md-out", default="coding_thinking_report.md", dest="md_out")
    args = p.parse_args(argv)

    prompt = Path(args.prompt_file).read_text(encoding="utf-8")
    conditions: list[ConditionSummary] = []

    if not args.skip_ollama:
        warm_err = ollama_warmup(args.ollama_host, args.ollama_model, args.n_ctx)
        if warm_err:
            print(f"[ollama] warmup probe failed (continuing): {warm_err}", file=sys.stderr)

        for thinking, n_predict, label in (
            (False, args.n_predict_off, "off"),
            (True, args.n_predict_on, "on"),
        ):
            print(f"=== ollama / thinking {label} ===", file=sys.stderr)
            summary = run_condition(
                "ollama", thinking, label, n_predict, args.n_ctx, args.warmup, args.repeat,
                lambda th=thinking, np=n_predict: stream_ollama(
                    args.ollama_host, args.ollama_model, prompt, think=th, n_predict=np, n_ctx=args.n_ctx
                ),
            )
            conditions.append(summary)
            print(f"  ok={summary.ok} ttft={summary.median_ttft_content_ms} tok/s={summary.median_content_tok_s}", file=sys.stderr)
    else:
        print("skipping ollama (--skip-ollama)", file=sys.stderr)

    if not args.skip_studio:
        if not args.studio_token:
            print("skipping unsloth-studio: no --studio-token / UNSLOTH_STUDIO_TOKEN set", file=sys.stderr)
        else:
            load_err = ensure_studio_loaded(args.studio_host, args.studio_token, args.studio_model, args.gguf_variant, args.n_ctx)
            if load_err:
                print(f"[unsloth-studio] load failed: {load_err}", file=sys.stderr)
            else:
                for thinking, n_predict, label, effort in (
                    (False, args.n_predict_off, "off", args.studio_reasoning_off),
                    (True, args.n_predict_on, "on", args.studio_reasoning_on),
                ):
                    print(f"=== unsloth-studio / thinking {label} (reasoning_effort={effort}) ===", file=sys.stderr)
                    summary = run_condition(
                        "unsloth-studio", thinking, label, n_predict, args.n_ctx, args.warmup, args.repeat,
                        lambda np=n_predict, ef=effort: stream_studio(
                            args.studio_host, args.studio_token, args.studio_model, prompt,
                            reasoning_effort=ef, n_predict=np,
                        ),
                    )
                    if effort == "high":
                        summary.notes.append(
                            "Studio's own chat template upgrades reasoning_effort='high' to 'xhigh' "
                            "internally (its most exhaustive thinking setting) - this condition is not "
                            "a moderate 'thinking on', it's the maximum."
                        )
                    conditions.append(summary)
                    print(f"  ok={summary.ok} ttft={summary.median_ttft_content_ms} tok/s={summary.median_content_tok_s}", file=sys.stderr)
    else:
        print("skipping unsloth-studio (--skip-studio)", file=sys.stderr)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "config": {
            "prompt_file": args.prompt_file,
            "n_ctx": args.n_ctx,
            "n_predict_off": args.n_predict_off,
            "n_predict_on": args.n_predict_on,
            "warmup": args.warmup,
            "repeat": args.repeat,
            "ollama_model": args.ollama_model,
            "studio_model": args.studio_model,
            "gguf_variant": args.gguf_variant,
        },
        "conditions": [asdict(c) for c in conditions],
    }
    json_path = out_dir / args.json_out
    md_path = out_dir / args.md_out
    json_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    md_path.write_text(render_markdown(conditions, args), encoding="utf-8")
    print(f"Wrote {json_path} and {md_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
