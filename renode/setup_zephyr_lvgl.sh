#!/usr/bin/env bash
set -euo pipefail

# setup_zephyr_lvgl.sh — bootstrap Zephyr workspace, install SDK, build LVGL demo
# Usage: ./setup_zephyr_lvgl.sh [WORKDIR] [BOARD] [DEMO]
#
# DEMO choices:
#   hello_world  — basic counter + touch button (default)
#   music        — music player UI
#   benchmark    — rendering performance test
#   stress       — memory/object stress test
#   widgets      — all built-in widget showcase
#   render       — scene render demo

WORKDIR="${1:-$HOME/zephyr-renode}"
BOARD="${2:-stm32f746g_disco}"
DEMO="${3:-hello_world}"
ZEPHYR_REMOTE="https://github.com/zephyrproject-rtos/zephyr.git"
LOG="$HOME/zephyr-build.log"

# Modules required for STM32F7 + LVGL; skips unrelated HALs (Nordic, NXP, …)
WEST_MODULES=(hal_stm32 hal_st cmsis cmsis_6 lvgl picolibc mbedtls)

log() { echo "$*" | tee -a "$LOG"; }

# Return the path to the Renode binary, or exit non-zero if not found.
find_renode() {
  for loc in \
    "$HOME/renode/renode" \
    "$HOME/.local/bin/renode" \
    "/opt/renode/renode"; do
    [ -x "$loc" ] && { echo "$loc"; return 0; }
  done
  command -v renode 2>/dev/null && return 0
  return 1
}

# Detect WSLg: must be running under WSL *and* have a live display socket.
has_wslg() {
  grep -qi microsoft /proc/version 2>/dev/null || return 1
  [ -d /mnt/wslg ] || [ -S /tmp/.X11-unix/X0 ] || \
    [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}
if has_wslg; then
  RENODE_FLAGS=""
  GUI_MODE="WSLg (GUI enabled)"
else
  RENODE_FLAGS="--disable-xwt"
  GUI_MODE="headless (--disable-xwt)"
fi

log "=== Zephyr+LVGL build for $BOARD / demo=$DEMO ($(date)) ==="
log "WORKDIR: $WORKDIR  Display: $GUI_MODE"

mkdir -p "$WORKDIR"
pushd "$WORKDIR" >/dev/null

VENV_DIR="$WORKDIR/.zephyr-venv"

run_west() {
  if [ -x "$VENV_DIR/bin/west" ]; then
    "$VENV_DIR/bin/west" "$@"
  elif command -v west >/dev/null 2>&1; then
    west "$@"
  else
    log "ERROR: 'west' not found."
    return 1
  fi
}

# ── 1: OS prerequisites ───────────────────────────────────────────────────────
log "[1/5] Installing OS prerequisites..."
sudo apt-get update -y >>"$LOG" 2>&1
sudo apt-get install -y \
  git cmake ninja-build python3-pip python3-venv \
  gperf ccache device-tree-compiler xz-utils file wget \
  >>"$LOG" 2>&1

# ── 2: West workspace ─────────────────────────────────────────────────────────
log "[2/5] Initializing west workspace..."
if [ ! -d "$WORKDIR/zephyr" ]; then
  if ! command -v west >/dev/null 2>&1 && [ ! -x "$VENV_DIR/bin/west" ]; then
    log "Creating virtualenv for west at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install -q --upgrade pip west >>"$LOG" 2>&1
  fi
  run_west init -m "$ZEPHYR_REMOTE" . >>"$LOG" 2>&1
  run_west update --narrow -o=--depth=1 "${WEST_MODULES[@]}" >>"$LOG" 2>&1
else
  log "Zephyr present; updating required modules only"
  git -C zephyr pull --ff-only >>"$LOG" 2>&1 || true
  run_west update --narrow -o=--depth=1 "${WEST_MODULES[@]}" >>"$LOG" 2>&1 || true
fi

# ── 3: Zephyr SDK ─────────────────────────────────────────────────────────────
log "[3/5] Installing Zephyr SDK..."
SDK_VERSION=$(cat "$WORKDIR/zephyr/SDK_VERSION" 2>/dev/null || echo "1.0.1")
ARCH=$(uname -m)
SDK_DIR="$HOME/zephyr-sdk-${SDK_VERSION}"

install_zephyr_sdk() {
  # ── Step A: locate or download the SDK bundle ────────────────────────────
  for loc in \
    "$SDK_DIR" \
    "$HOME/.local/zephyr-sdk-${SDK_VERSION}" \
    "$HOME/.local/opt/zephyr-sdk-${SDK_VERSION}" \
    "/opt/zephyr-sdk-${SDK_VERSION}"; do
    # SDK 1.0+ puts the cmake config inside a cmake/ subdirectory
    if [ -f "$loc/cmake/Zephyr-sdkConfig.cmake" ] || [ -f "$loc/Zephyr-sdkConfig.cmake" ]; then
      log "Found Zephyr SDK ${SDK_VERSION} at $loc"
      SDK_DIR="$loc"
      break
    fi
  done

  if [ ! -f "$SDK_DIR/cmake/Zephyr-sdkConfig.cmake" ] && [ ! -f "$SDK_DIR/Zephyr-sdkConfig.cmake" ]; then
    local tmp="/tmp/zephyr-sdk-${SDK_VERSION}-minimal.tar.xz"
    local url="https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${SDK_VERSION}/zephyr-sdk-${SDK_VERSION}_linux-${ARCH}_minimal.tar.xz"
    log "Downloading Zephyr SDK ${SDK_VERSION}..."
    wget -q --show-progress -O "$tmp" "$url" 2>&1 | tee -a "$LOG"
    tar -xf "$tmp" -C "$HOME"
    rm -f "$tmp"
    [ -d "$SDK_DIR" ] || { log "ERROR: SDK extraction failed; expected $SDK_DIR"; exit 1; }
  fi

  # ── Step B: install ARM toolchain if not already present ─────────────────
  # SDK 1.0+ stores toolchains under gnu/; older releases used the root directly
  local toolchain_gcc="$SDK_DIR/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc"
  [ -x "$toolchain_gcc" ] || toolchain_gcc="$SDK_DIR/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc"
  if [ ! -x "$toolchain_gcc" ]; then
    log "Installing arm-zephyr-eabi toolchain..."
    "$SDK_DIR/setup.sh" -t arm-zephyr-eabi -c >>"$LOG" 2>&1
    return 0
  fi

  # ── Step C: ensure CMake user registry entry exists ───────────────────────
  local cmake_reg="$HOME/.cmake/packages/Zephyr-sdk"
  if [ ! -d "$cmake_reg" ] || ! grep -rlq "$SDK_DIR" "$cmake_reg" 2>/dev/null; then
    log "Registering SDK ${SDK_VERSION} in CMake package registry..."
    "$SDK_DIR/setup.sh" -c >>"$LOG" 2>&1
  else
    log "Zephyr SDK ${SDK_VERSION} with arm-zephyr-eabi already installed — skipping."
  fi
}
install_zephyr_sdk

# ── 4: Python requirements ────────────────────────────────────────────────────
log "[4/5] Installing Python requirements..."
if [ -x "$VENV_DIR/bin/pip" ]; then
  "$VENV_DIR/bin/pip" install -q -r zephyr/scripts/requirements.txt >>"$LOG" 2>&1
else
  python3 -m pip install -q --user -r zephyr/scripts/requirements.txt >>"$LOG" 2>&1
fi

# ── 5: Build LVGL sample ──────────────────────────────────────────────────────
log "[5/5] Building LVGL demo '$DEMO' for $BOARD..."

# Resolve sample directory and optional Kconfig override from DEMO name
case "$DEMO" in
  hello_world)
    SAMPLE_DIR="zephyr/samples/subsys/display/lvgl"
    DEMO_KCONFIG=""
    ;;
  music)
    SAMPLE_DIR="zephyr/samples/modules/lvgl/demos"
    DEMO_KCONFIG="-DCONFIG_LV_Z_DEMO_MUSIC=y"
    ;;
  benchmark)
    SAMPLE_DIR="zephyr/samples/modules/lvgl/demos"
    DEMO_KCONFIG="-DCONFIG_LV_Z_DEMO_BENCHMARK=y"
    ;;
  stress)
    SAMPLE_DIR="zephyr/samples/modules/lvgl/demos"
    DEMO_KCONFIG="-DCONFIG_LV_Z_DEMO_STRESS=y"
    ;;
  widgets)
    SAMPLE_DIR="zephyr/samples/modules/lvgl/demos"
    DEMO_KCONFIG="-DCONFIG_LV_Z_DEMO_WIDGETS=y"
    ;;
  render)
    SAMPLE_DIR="zephyr/samples/modules/lvgl/demos"
    DEMO_KCONFIG="-DCONFIG_LV_Z_DEMO_RENDER=y"
    ;;
  *)
    log "ERROR: Unknown demo '$DEMO'. Choose: hello_world music benchmark stress widgets render"
    exit 1
    ;;
esac

[ -d "$SAMPLE_DIR" ] || { log "ERROR: Sample directory not found: $SAMPLE_DIR"; exit 1; }

BUILD_DIR="$WORKDIR/build_${BOARD}_${DEMO}"
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export CCACHE_DIR="$WORKDIR/.ccache"   # persistent cache for incremental rebuilds

# shellcheck disable=SC2086  # DEMO_KCONFIG may be empty or a single word
run_west build -b "$BOARD" "$SAMPLE_DIR" -d "$BUILD_DIR" \
  -- -DCMAKE_PREFIX_PATH="$SDK_DIR" \
     -DCMAKE_C_COMPILER_LAUNCHER=ccache \
     -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
     $DEMO_KCONFIG \
  2>&1 | tee -a "$LOG" \
  || { log "Build failed — see $LOG"; exit 1; }

# ── Artifacts & Renode script ─────────────────────────────────────────────────
ARTIFACT="$BUILD_DIR/zephyr/zephyr.elf"
[ -f "$ARTIFACT" ] || { log "ERROR: artifact not found at $ARTIFACT"; exit 1; }
log "Build successful. Artifact: $ARTIFACT"

popd >/dev/null

RENODE_BIN=$(find_renode || true)
if [ -n "$RENODE_BIN" ]; then
  RENODE_RESC="$WORKDIR/run_${BOARD}.resc"
  cat > "$RENODE_RESC" <<RESC_EOF
# Renode script for ${BOARD} — generated by setup_zephyr_lvgl.sh
# Run: renode ${RENODE_FLAGS} -e "i @${RENODE_RESC}; start"

using sysbus

mach create "${BOARD}"
machine LoadPlatformDescription @platforms/boards/stm32f7_discovery-bb.repl

sysbus LoadELF @${ARTIFACT}

showAnalyzer sysbus.usart1
showAnalyzer "display" sysbus.ltdc
#connector Connect sysbus.i2c3.touchscreen sysbus.ltdc
start
RESC_EOF
  log "Generated Renode script : $RENODE_RESC"
  log "Run: $RENODE_BIN ${RENODE_FLAGS:-(no extra flags)} -e \"i @${RENODE_RESC}; start\""
  log "  or: ./run_renode_lvgl.sh $WORKDIR $BOARD"
else
  log "[INFO] Renode not found — skipping .resc generation."
  log "[INFO] Run install_renode.sh, then: ./run_renode_lvgl.sh $WORKDIR $BOARD"
fi

log "==== Done. Log: $LOG ===="
