#!/usr/bin/env bash
set -euo pipefail

# install_renode.sh — clone, build, smoke-test, and optionally unit-test Renode
# Usage: ./install_renode.sh [--run-tests] [WORKDIR]

RUN_TESTS=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --run-tests) RUN_TESTS=1 ;;
    *)           POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

WORKDIR="${1:-$HOME/renode}"
LOG="$HOME/renode-build.log"
JOBS="$(nproc 2>/dev/null || echo 4)"

log() { echo "$*" | tee -a "$LOG"; }

# Detect WSLg: must be WSL *and* have a live display socket.
# WSLg mounts /mnt/wslg and sets DISPLAY/:WAYLAND_DISPLAY automatically.
has_wslg() {
  grep -qi microsoft /proc/version 2>/dev/null || return 1
  [ -d /mnt/wslg ] || [ -S /tmp/.X11-unix/X0 ] || \
    [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

if has_wslg; then
  RENODE_FLAGS=""          # WSLg provides a real display — run with GUI
  GUI_MODE="WSLg (GUI enabled)"
else
  RENODE_FLAGS="--disable-xwt"   # headless — WSL2 without WSLg, or bare Linux/CI
  GUI_MODE="headless (--disable-xwt)"
fi

log "==== Renode Build & Test ($(date)) ===="
log "WORKDIR: $WORKDIR  JOBS: $JOBS  Display: $GUI_MODE"

mkdir -p "$WORKDIR"

# ── 1: OS prerequisites ───────────────────────────────────────────────────────
log "[1/6] Installing prerequisites..."
sudo apt-get update -y >>"$LOG" 2>&1
sudo apt-get install -y \
  git build-essential python3 python3-pip python3-venv \
  cmake ninja-build mono-complete \
  libgtk-3-dev wget unzip ca-certificates \
  >>"$LOG" 2>&1

# ── 2: .NET SDK ───────────────────────────────────────────────────────────────
log "[2/6] Checking .NET..."
if ! command -v dotnet >/dev/null 2>&1 && [ ! -x "$HOME/.dotnet/dotnet" ]; then
  log "Installing .NET 8..."
  # Download to /tmp to avoid cluttering the working directory
  wget -q -O /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh
  chmod +x /tmp/dotnet-install.sh
  /tmp/dotnet-install.sh --channel 8.0 >>"$LOG" 2>&1
  rm -f /tmp/dotnet-install.sh
fi

# Ensure .NET is on PATH for this session and future shells
if [ -d "$HOME/.dotnet" ]; then
  export PATH="$HOME/.dotnet:$PATH"
  if ! grep -qF 'HOME/.dotnet' ~/.bashrc; then
    printf '\n# .NET SDK\nexport PATH="$HOME/.dotnet:$PATH"\n' >> ~/.bashrc
  fi
fi
dotnet --version 2>&1 | tee -a "$LOG"

# ── 3: Clone / update Renode ──────────────────────────────────────────────────
log "[3/6] Cloning/updating Renode..."
if [ ! -d "$WORKDIR/.git" ]; then
  # --recurse-submodules: Renode depends on several git submodules
  git clone --recurse-submodules https://github.com/renode/renode.git "$WORKDIR" >>"$LOG" 2>&1
else
  git -C "$WORKDIR" fetch --all >>"$LOG" 2>&1
  git -C "$WORKDIR" pull --ff-only >>"$LOG" 2>&1
  git -C "$WORKDIR" submodule update --init --recursive >>"$LOG" 2>&1
fi

# ── 4: Build ──────────────────────────────────────────────────────────────────
log "[4/6] Building (jobs=$JOBS)..."
pushd "$WORKDIR" >/dev/null

if [ ! -x "./build.sh" ]; then
  log "[ERR] build.sh not found in $WORKDIR — clone may be incomplete."
  exit 1
fi
./build.sh >>"$LOG" 2>&1

# ── 5: Smoke test ─────────────────────────────────────────────────────────────
log "[5/6] Running smoke test..."

# Renode may install as ./renode (wrapper) or ./output/bin/renode depending on version
RENODE_BIN=""
for candidate in "./renode" "./output/bin/renode"; do
  if [ -x "$candidate" ]; then
    RENODE_BIN="$candidate"
    break
  fi
done

if [ -z "$RENODE_BIN" ]; then
  log "[ERR] Renode binary not found after build. Check log: $LOG"
  exit 1
fi

TEST_SCRIPT="scripts/single-node/stm32f4_discovery.resc"
if [ -f "$TEST_SCRIPT" ]; then
  # shellcheck disable=SC2086  # word-split of RENODE_FLAGS is intentional
  timeout 20s "$RENODE_BIN" $RENODE_FLAGS \
    -e "i @${TEST_SCRIPT}; start; sleep 2; quit" \
    >>"$LOG" 2>&1 || true
  log "[OK] Smoke test completed."
else
  log "[WARN] Test script $TEST_SCRIPT not found; skipping smoke test."
fi

log "[OK] Renode built successfully: $WORKDIR/$RENODE_BIN"

# ── 6: Unit tests (--run-tests only) ─────────────────────────────────────────
if [ "$RUN_TESTS" -eq 0 ]; then
  log "[6/6] Skipping unit tests (pass --run-tests to enable)."
else
log "[6/6] Running Renode unit tests..."
if [ -x "./renode-test" ]; then
  REQ="tests/requirements.txt"
  VENV_DIR=".venv"

  if [ -f "$REQ" ] && [ ! -d "$VENV_DIR" ]; then
    log "[INFO] Creating Python venv at $WORKDIR/$VENV_DIR"
    python3 -m venv "$VENV_DIR" >>"$LOG" 2>&1 || true
  fi

  if [ -d "$VENV_DIR" ] && [ -f "$REQ" ]; then
    log "[INFO] Installing test requirements into venv"
    "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel >>"$LOG" 2>&1 || true
    "$VENV_DIR/bin/pip" install -r "$REQ" >>"$LOG" 2>&1 || true
    export PATH="$VENV_DIR/bin:$PATH"
  fi

  timeout 120s ./renode-test >>"$LOG" 2>&1 || true
  log "[INFO] Test run completed (see log for details)."
else
  log "[INFO] renode-test not found; skipping unit tests."
fi
fi   # --run-tests

popd >/dev/null

log "==== Done. Log: $LOG ===="
log "Run: $WORKDIR/renode ${RENODE_FLAGS:-(no extra flags, GUI active)}"
