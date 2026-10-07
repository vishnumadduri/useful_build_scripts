#!/usr/bin/env bash
# Show or set Ollama's default context length (OLLAMA_CONTEXT_LENGTH).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$HERE/lib/common.sh"

usage() {
  cat <<USAGE
Usage: ./ollama-context.sh [command]

Commands:
  show             Show the configured default context length (default)
  set SIZE         Set it, e.g. 8192, 32768 or 32k, 128k  (512 - 1048576)
  reset            Remove the override; Ollama picks its own default
  -h, --help       Show this help

Applies to every model that does not set its own num_ctx (a Modelfile
'PARAMETER num_ctx' or an API request overrides it). Larger contexts use
more VRAM (KV cache), and the cost is multiplied by OLLAMA_NUM_PARALLEL.
Independent of the GPU backend. Restarts Ollama (unloads loaded models).
USAGE
}

current_ctx() {
  systemctl show "$SERVICE_NAME" -p Environment --value 2>/dev/null |
    { grep -oE 'OLLAMA_CONTEXT_LENGTH=[0-9]+' || true; } | head -1 | cut -d= -f2
}

parse_size() {
  local v="${1,,}"
  case "$v" in
    *k) [[ ${v%k} =~ ^[0-9]+$ ]] && echo $((${v%k} * 1024)) ;;
    *)  [[ $v =~ ^[0-9]+$ ]] && echo "$v" ;;
  esac
}

cmd_show() {
  local c; c="$(current_ctx)"
  hdr "Context length"
  if [[ -n $c ]]; then ok "Default context: $c tokens  ($CONTEXT_DROPIN)"
  else info "No override set; Ollama uses its built-in default."; fi
  if api_ready; then
    echo "  Loaded models:"
    "$(ollama_bin)" ps 2>/dev/null | sed 's/^/    /' || true
  fi
}

cmd_set() {
  local n; n="$(parse_size "${1:-}" || true)"
  [[ -n $n ]] || { err "Invalid size '${1:-}'. Use e.g. 8192, 32768, 32k."; exit 2; }
  ((n >= 512 && n <= 1048576)) || die "Context must be between 512 and 1048576 (got $n)."
  ((n > 32768)) && warn "$n tokens needs a lot of VRAM (KV cache); the model may spill to CPU."
  need_cmd systemctl curl
  service_exists || die "Service '$SERVICE_NAME' not found. Run ./install.sh first."

  local prev=""; [[ -f $CONTEXT_DROPIN ]] && prev="$(cat "$CONTEXT_DROPIN")"
  if printf '# ollama-setup context length\n[Service]\nEnvironment="OLLAMA_CONTEXT_LENGTH=%s"\n' "$n" |
       write_if_changed "$CONTEXT_DROPIN"; then
    ok "Wrote $CONTEXT_DROPIN"
  else
    ok "Already set to $n"; service_active && [[ "$(current_ctx)" == "$n" ]] && return 0
  fi
  info "Restarting $SERVICE_NAME..."
  if restart_service; then
    ok "Ollama restarted with default context $n"
  else
    err "Ollama failed to start; restoring previous setting."
    if [[ -n $prev ]]; then printf '%s\n' "$prev" >"$CONTEXT_DROPIN"; else rm -f "$CONTEXT_DROPIN"; fi
    restart_service || true
    die "Reverted. Inspect: journalctl -u $SERVICE_NAME -n 50"
  fi
}

cmd_reset() {
  [[ -f $CONTEXT_DROPIN ]] || { ok "No override set."; return 0; }
  rm -f "$CONTEXT_DROPIN"
  restart_service && ok "Override removed; Ollama default in use." || die "Ollama failed to start."
}

cmd="${1:-show}"
case "$cmd" in
  -h|--help) usage ;;
  show) cmd_show ;;
  set)   ensure_root "$@"; init_state; shift; cmd_set "$@" ;;
  reset) ensure_root "$@"; init_state; cmd_reset ;;
  *) err "Unknown command: $cmd"; usage >&2; exit 2 ;;
esac
