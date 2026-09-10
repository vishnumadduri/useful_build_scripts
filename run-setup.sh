#!/usr/bin/env bash
# Run a documented Linux/WSL setup helper from this repository.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./run-setup.sh list
  ./run-setup.sh <target> [--dry-run] [-- <target arguments...>]

Targets:
  renode       Install and smoke-test Renode
  zephyr-lvgl  Set up and build a Zephyr + LVGL demo for Renode
  ros2         Install a ROS 2 development environment
  unsloth-amd  Install Unsloth Core for AMD on Linux/WSL

Use `--dry-run` to print the command without running it. Target arguments are
forwarded unchanged; `--` is optional but recommended when the first target
argument begins with a dash.
EOF
}

list_targets() {
  usage
  cat <<'EOF'

Documentation:
  renode / zephyr-lvgl  renode/README.md
  ros2                  robotics/ros2-setup/README.md
  unsloth-amd           ai-setup/unsloth-setup/README.md
EOF
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  list)
    list_targets
    exit 0
    ;;
esac

target_name="$1"
shift

case "$target_name" in
  renode) target="renode/install_renode.sh" ;;
  zephyr-lvgl) target="renode/setup_zephyr_lvgl.sh" ;;
  ros2) target="robotics/ros2-setup/setup_ros2_env.sh" ;;
  unsloth-amd) target="ai-setup/unsloth-setup/install_unsloth_amd.sh" ;;
  *)
    printf 'Unknown target: %s\n\n' "$target_name" >&2
    usage >&2
    exit 2
    ;;
esac

dry_run=false
if [[ ${1:-} == "--dry-run" ]]; then
  dry_run=true
  shift
fi
if [[ ${1:-} == "--" ]]; then
  shift
fi

script_path="$repo_root/$target"
if [[ ! -f "$script_path" ]]; then
  printf 'Expected setup script is missing: %s\n' "$script_path" >&2
  exit 1
fi

if "$dry_run"; then
  printf 'Would run: bash %q' "$script_path"
  printf ' %q' "$@"
  printf '\n'
  exit 0
fi

printf 'Running %s\n' "$target"
exec bash "$script_path" "$@"
