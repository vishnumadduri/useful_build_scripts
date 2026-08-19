#!/usr/bin/env bash
set -euo pipefail

# setup_ros2_env.sh — install a ROS 2 distro + development tools, configure environment
# Usage: ./setup_ros2_env.sh DISTRO [VARIANT] [WORKSPACE_DIR] [--force]
#
# DISTRO   (required): humble | jazzy | kilted | rolling
# VARIANT  (optional):  desktop (default) | ros-base | core
# WORKSPACE_DIR (optional): colcon workspace to create, default ~/ros2_ws
# --force  (optional): install even if the running Ubuntu release doesn't match
#                       the distro's required codename (apt-get install will
#                       then likely fail with unmet dependencies)

FORCE=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [ $# -lt 1 ]; then
  echo "Usage: $0 DISTRO [VARIANT] [WORKSPACE_DIR] [--force]" >&2
  echo "  DISTRO   : humble | jazzy | kilted | rolling" >&2
  echo "  VARIANT  : desktop (default) | ros-base | core" >&2
  exit 1
fi

DISTRO="$1"
VARIANT="${2:-desktop}"
WS="${3:-$HOME/ros2_ws}"
LOG="$HOME/ros2-setup-${DISTRO}.log"

log() { echo "$*" | tee -a "$LOG"; }

# Maps each distro to the Ubuntu codename it requires (per REP 2000 / ros.org).
# iron (jammy) is intentionally omitted — EOL since 2024-11.
declare -A DISTRO_UBUNTU=(
  [humble]="jammy"
  [jazzy]="noble"
  [kilted]="noble"
  [rolling]="noble"
)
[ -n "${DISTRO_UBUNTU[$DISTRO]:-}" ] || {
  log "ERROR: Unknown or unsupported DISTRO '$DISTRO'. Choose: ${!DISTRO_UBUNTU[*]}"
  exit 1
}

case "$VARIANT" in
  desktop) ROS_PKG="ros-${DISTRO}-desktop" ;;
  ros-base) ROS_PKG="ros-${DISTRO}-ros-base" ;;
  core) ROS_PKG="ros-${DISTRO}-ros-core" ;;
  *)
    log "ERROR: Unknown VARIANT '$VARIANT'. Choose: desktop | ros-base | core"
    exit 1
    ;;
esac

UBUNTU_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
REQUIRED_CODENAME="${DISTRO_UBUNTU[$DISTRO]}"
if [ "$UBUNTU_CODENAME" != "$REQUIRED_CODENAME" ]; then
  if [ "$FORCE" -eq 1 ]; then
    log "WARNING: $DISTRO requires Ubuntu $REQUIRED_CODENAME, but this system is '$UBUNTU_CODENAME'. --force set, continuing anyway."
  else
    log "ERROR: $DISTRO requires Ubuntu $REQUIRED_CODENAME, but this system is '$UBUNTU_CODENAME'."
    log "The ROS 2 apt repo has no packages built for '$UBUNTU_CODENAME' under this distro — install would fail."
    log "Re-run with --force to attempt it anyway, or pick a distro matching this Ubuntu release."
    exit 1
  fi
fi

log "=== ROS 2 '$DISTRO' ($VARIANT) setup ($(date)) ==="
log "Workspace: $WS"

# ── 1: Locale ──────────────────────────────────────────────────────────────
log "[1/7] Ensuring UTF-8 locale..."
if ! locale -a 2>/dev/null | grep -qi "en_US.utf8"; then
  sudo apt-get update -y >>"$LOG" 2>&1
  sudo apt-get install -y locales >>"$LOG" 2>&1
  sudo locale-gen en_US en_US.UTF-8 >>"$LOG" 2>&1
  sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 >>"$LOG" 2>&1
fi
export LANG=en_US.UTF-8

# ── 2: ROS 2 apt repository ──────────────────────────────────────────────────
log "[2/7] Configuring ROS 2 apt repository..."
sudo apt-get update -y >>"$LOG" 2>&1
sudo apt-get install -y curl gnupg2 lsb-release software-properties-common >>"$LOG" 2>&1
sudo add-apt-repository -y universe >>"$LOG" 2>&1

KEYRING=/usr/share/keyrings/ros-archive-keyring.gpg
if [ ! -f "$KEYRING" ]; then
  curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    | sudo gpg --dearmor -o "$KEYRING"
fi

SOURCES_LIST=/etc/apt/sources.list.d/ros2.list
echo "deb [arch=$(dpkg --print-architecture) signed-by=$KEYRING] http://packages.ros.org/ros2/ubuntu $UBUNTU_CODENAME main" \
  | sudo tee "$SOURCES_LIST" >>"$LOG"

# ── 3: Install ROS 2 ──────────────────────────────────────────────────────────
log "[3/7] Installing $ROS_PKG..."
sudo apt-get update -y >>"$LOG" 2>&1
sudo apt-get install -y "$ROS_PKG" >>"$LOG" 2>&1

# ── 4: Development tools ──────────────────────────────────────────────────────
# ros-dev-tools is the official metapackage (colcon, rosdep, vcstool, argcomplete,
# rosinstall-generator, lint tools, ...); build-essential/cmake/git/pip aren't part of it.
log "[4/7] Installing development tools..."
sudo apt-get install -y \
  ros-dev-tools \
  python3-pip \
  build-essential \
  cmake \
  git \
  >>"$LOG" 2>&1

# ── 5: rosdep ──────────────────────────────────────────────────────────────────
log "[5/7] Initializing rosdep..."
if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
  sudo rosdep init >>"$LOG" 2>&1
else
  log "rosdep already initialized — skipping init"
fi
rosdep update >>"$LOG" 2>&1

# ── 6: Workspace ──────────────────────────────────────────────────────────────
log "[6/7] Creating colcon workspace at $WS..."
mkdir -p "$WS/src"

# ── 7: Shell environment ──────────────────────────────────────────────────────
log "[7/7] Configuring shell environment..."
BASHRC="$HOME/.bashrc"
add_once() {
  local line="$1"
  grep -qxF "$line" "$BASHRC" 2>/dev/null || echo "$line" >>"$BASHRC"
}
add_once "source /opt/ros/${DISTRO}/setup.bash"
add_once "[ -f \"$WS/install/setup.bash\" ] && source \"$WS/install/setup.bash\""
add_once "source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash 2>/dev/null || true"
add_once "export ROS_DISTRO=${DISTRO}"

log "==== Done. ===="
log "Installed: $ROS_PKG"
log "Workspace: $WS"
log "Log: $LOG"
log ""
log "Open a new shell (or 'source ~/.bashrc') to pick up the ROS 2 environment."
