#!/usr/bin/env bash
# Find, report and relocate the Ollama model store used by the systemd service.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$HERE/lib/common.sh"

usage() {
  cat <<USAGE
Usage: ./ollama-models.sh [command]

Commands:
  show               Show the directory the Ollama service uses (default)
  scan               Search the machine for existing model stores
  set PATH [--migrate]
                     Point the service at PATH (OLLAMA_MODELS drop-in).
                     --migrate copies existing models from the current store first.
  reset              Remove the override; use the service default
  -h, --help         Show this help

Models are independent of the GPU backend: switching AMD <-> NVIDIA never
touches them. Models downloaded by 'ollama serve' run as YOUR user live in
~/.ollama/models, but the systemd service uses its own store (default:
/usr/share/ollama/.ollama/models) unless OLLAMA_MODELS is set.
USAGE
}

print_dir() {
  local d="$1" tag="${2:-}"
  if [[ -d $d ]]; then
    printf '  %-45s %4s models, %6s %s\n' "$d" "$(models_count "$d")" "$(models_size "$d")" "$tag"
  else
    printf '  %-45s (missing) %s\n' "$d" "$tag"
  fi
}

cmd_show() {
  local eff; eff="$(effective_models_dir)"
  hdr "Model storage"
  print_dir "$eff" "<- used by the $SERVICE_NAME service"
  if [[ -f $MODELS_DROPIN ]]; then info "Override set by $MODELS_DROPIN"; else info "Service default (no override)"; fi
  local others=0 d
  while read -r d; do
    [[ $d == "$eff" || ! -d $d ]] && continue
    models_has "$d" || continue
    ((others++)) || { echo; warn "Other model stores with models exist (NOT used by the service):"; }
    print_dir "$d"
  done < <(candidate_models_dirs)
  if ((others)); then
    echo "  To use one: ./ollama-models.sh set <path> [--migrate]"
  fi
  df -h "$(dirname "$eff")" 2>/dev/null | sed -n '2p' | awk '{printf "\n  Disk: %s free of %s on %s\n", $4, $2, $6}' || true
}

cmd_scan() {
  hdr "Scanning for Ollama model stores"
  local d found=0
  while read -r d; do
    [[ -d $d ]] || continue
    print_dir "$d"; found=1
  done < <(candidate_models_dirs)
  ((found)) || info "No model stores found."
}

cmd_set() {
  local path="${1:-}" migrate=0
  [[ -n $path ]] || { err "set requires a PATH"; usage >&2; exit 2; }
  [[ ${2:-} == --migrate ]] && migrate=1
  [[ $path == /* ]] || die "PATH must be absolute: $path"
  path="${path%/}"
  local old; old="$(effective_models_dir)"

  id "$SERVICE_NAME" >/dev/null 2>&1 || die "Service user '$SERVICE_NAME' missing; run ./install.sh first."
  mkdir -p "$path"
  chown "$SERVICE_NAME:$SERVICE_NAME" "$path"
  runuser -u "$SERVICE_NAME" -- test -w "$path" ||
    die "User '$SERVICE_NAME' cannot write to $path (check that every parent directory is traversable, e.g. chmod o+x)."

  if [[ $path != "$old" && -d $old ]] && models_has "$old"; then
    if ((migrate)); then
      need_cmd rsync
      info "Stopping service and copying $old -> $path ..."
      systemctl stop "$SERVICE_NAME" 2>/dev/null || true
      rsync -a --info=progress2 "$old"/ "$path"/
      chown -R "$SERVICE_NAME:$SERVICE_NAME" "$path"
      ok "Copy complete (the old store was left in place; delete it yourself once verified)."
    else
      warn "Existing models in $old will not be moved. Re-run with --migrate to copy them."
    fi
  fi

  if printf '# ollama-setup models directory\n[Service]\nEnvironment="OLLAMA_MODELS=%s"\n' "$path" |
       write_if_changed "$MODELS_DROPIN"; then
    ok "Wrote $MODELS_DROPIN"
  else
    ok "Already configured for $path"
  fi
  restart_service && ok "Ollama restarted using $path" || die "Ollama failed to start. Inspect: journalctl -u $SERVICE_NAME -n 50"
}

cmd_reset() {
  if [[ -f $MODELS_DROPIN ]]; then
    rm -f "$MODELS_DROPIN"
    restart_service && ok "Override removed; service default in use: $(effective_models_dir)" || die "Ollama failed to start."
  else
    ok "No override set."
  fi
}

cmd="${1:-show}"
case "$cmd" in
  -h|--help) usage ;;
  show) cmd_show ;;
  scan) cmd_scan ;;
  set)   ensure_root "$@"; init_state; shift; cmd_set "$@" ;;
  reset) ensure_root "$@"; init_state; cmd_reset ;;
  *) err "Unknown command: $cmd"; usage >&2; exit 2 ;;
esac
