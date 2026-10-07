#!/usr/bin/env bash
# Shared switching logic for use-amd.sh / use-nvidia.sh. Source after common.sh.

switch_usage() {
  local backend="$1" label="$2" script="$3"
  cat <<EOF
Usage: $script [options]

Switch the single Ollama installation to the $label backend.
Validates drivers, writes a systemd drop-in, restarts Ollama and verifies the
GPU is picked up. If anything fails, the previous configuration is restored.

Options:
  -f, --force     Continue past 'unsupported GPU/driver' validation errors
  -n, --dry-run   Validate and show the configuration, change nothing
  -h, --help      Show this help

Optional per-backend overrides: config/$backend.env (KEY=VALUE lines)
EOF
  [[ $backend == nvidia ]] && echo "Select specific GPUs with NVIDIA_GPU_IDS=0,1 $script"
  return 0
}

# switch_backend <amd|nvidia> <script-name> <args...>
switch_backend() {
  local backend="$1" script="$2"; shift 2
  local label dry=0 orig=("$@")
  [[ $backend == amd ]] && label="AMD ROCm (Radeon AI PRO R9700)" || label="NVIDIA CUDA"
  FORCE=0

  while (($#)); do
    case "$1" in
      -f|--force) FORCE=1 ;;
      -n|--dry-run) dry=1 ;;
      -h|--help) switch_usage "$backend" "$label" "$script"; exit 0 ;;
      *) err "Unknown option: $1"; switch_usage "$backend" "$label" "$script" >&2; exit 2 ;;
    esac
    shift
  done

  ((dry)) || ensure_root "${orig[@]}"
  ((dry)) || init_state

  hdr "Switching Ollama to $label"
  [[ -n "$(ollama_bin)" ]] || die "Ollama is not installed. Run ./install.sh first."
  need_cmd systemctl curl
  service_exists || die "systemd unit '$SERVICE_NAME' not found. Run ./install.sh to create it."

  info "Validating $label environment..."
  if [[ $backend == amd ]]; then validate_amd || die "AMD validation failed; nothing was changed."
  else validate_nvidia || die "NVIDIA validation failed; nothing was changed."; fi
  ok "Drivers and GPU look good${VALID_IDS:+ (device ids: $VALID_IDS)}"

  local want current
  want="$(render_gpu_dropin "$backend" "$VALID_IDS")"
  current="$(current_backend)"

  if ((dry)); then
    info "Dry run: would write $GPU_DROPIN:"
    sed 's/^/    /' <<<"$want"
    return 0
  fi

  # Idempotency: already on this backend, config identical, service healthy.
  if [[ $current == "$backend" && -f $GPU_DROPIN ]] && [[ "$(cat "$GPU_DROPIN")" == "$want" ]] \
     && service_active && api_ready; then
    ok "Already using $label with identical configuration; nothing to do."
    info "Run ./ollama-status.sh for details."
    return 0
  fi

  local snap since
  snap="$(snapshot_config)"
  info "Saved previous configuration (backend: $current) as backup '$snap'"

  printf '%s\n' "$want" | write_if_changed "$GPU_DROPIN" || true
  ok "Wrote $GPU_DROPIN"

  if service_active; then
    local loaded
    loaded="$(curl -fsS -m 3 "$OLLAMA_API/api/ps" 2>/dev/null | grep -o '"name"' | wc -l || true)"
    ((${loaded:-0} > 0)) && warn "$loaded model(s) currently loaded; the restart will unload them."
  fi

  since="$(date '+%Y-%m-%d %H:%M:%S')"
  info "Restarting $SERVICE_NAME..."
  if ! restart_service; then
    err "Service failed to become ready after the switch."
    switch_rollback "$snap" "$current"
    exit 1
  fi
  ok "Service is up"

  info "Verifying GPU acceleration (waiting for Ollama's device discovery)..."
  VERIFY_FOUND=""
  local rc=0
  verify_gpu "$backend" "$since" 25 || rc=$?
  case $rc in
    0) ok "Ollama is using the $label backend." ;;
    2) warn "Ollama did not log device discovery; could not confirm the backend yet."
       warn "Load a model and run ./ollama-status.sh to confirm." ;;
    *) err "Ollama did not select the $label backend (reported: ${VERIFY_FOUND:-none})."
       switch_rollback "$snap" "$current"
       exit 1 ;;
  esac

  echo
  ok "Done. Active backend: $backend. Undo with ./rollback.sh"
}

# Restore the snapshot and restart so a failed switch leaves a working setup.
switch_rollback() {
  local snap="$1" prev="$2"
  warn "Rolling back to the previous configuration (backend: $prev)..."
  restore_snapshot "$snap" || die "Could not restore backup '$snap' from $BACKUP_DIR"
  if restart_service; then
    ok "Previous configuration restored and Ollama is running."
  else
    err "Ollama still fails to start after rollback. Inspect: journalctl -u $SERVICE_NAME -n 50"
  fi
}
