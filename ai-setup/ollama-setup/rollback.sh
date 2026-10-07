#!/usr/bin/env bash
# Restore a previous GPU configuration saved by use-amd.sh / use-nvidia.sh.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$HERE/lib/common.sh"

usage() {
  cat <<USAGE
Usage: ./rollback.sh [options] [BACKUP_ID]

Restore the GPU configuration saved before the last switch (or BACKUP_ID),
then restart Ollama. The current configuration is snapshotted first, so
running rollback twice toggles between the two states.

Options:
  -l, --list    List available backups
  -h, --help    Show this help
USAGE
}

target=""
while (($#)); do
  case "$1" in
    -l|--list)
      if [[ -d $BACKUP_DIR ]]; then
        last="$(cat "$STATE_DIR/last-backup" 2>/dev/null || true)"
        while read -r id; do
          printf '  %s%s\n' "$id" "$([[ $id == "$last" ]] && echo '   <- default rollback target')"
        done < <(list_snapshots)
      fi
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) err "Unknown option: $1"; usage >&2; exit 2 ;;
    *) target="$1" ;;
  esac
  shift
done

ensure_root "$@"
init_state
need_cmd systemctl curl

[[ -n $target ]] || target="$(cat "$STATE_DIR/last-backup" 2>/dev/null || true)"
[[ -n $target ]] || die "No backups found in $BACKUP_DIR. Nothing to roll back."
[[ -d $BACKUP_DIR/$target ]] || die "Backup '$target' not found (see ./rollback.sh --list)."

hdr "Rolling back GPU configuration"
before="$(current_backend)"
snapshot_config >/dev/null
info "Restoring backup '$target' (current backend: $before)"
restore_snapshot "$target"
if restart_service; then
  ok "Ollama restarted. Active backend is now: $(current_backend)"
else
  die "Ollama failed to start after rollback. Inspect: journalctl -u $SERVICE_NAME -n 50"
fi
