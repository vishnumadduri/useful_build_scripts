#!/bin/sh
# code-server install script adapted for Yocto embedded systems.
# Uses opkg package manager and is compatible with busybox sh.
#
# Original script: https://code-server.dev/install.sh
# (https://github.com/cdr/code-server)
#
# Usage:
#   sh install_code_server_yocto.sh [--dry-run] [--version X.X.X] [--method detect|standalone|opkg] [--prefix /usr/local]
#
# Requires: wget (with HTTPS/TLS support), tar, awk, sed, grep, uname

set -eu

usage() {
  arg0="$0"
  cat << EOF
Installs code-server on a Yocto / OpenEmbedded system.

Uses opkg if available and a suitable feed is configured,
otherwise downloads and installs a standalone release from GitHub.

Requires wget with HTTPS/TLS support (CONFIG_FEATURE_WGET_HTTPS or
a wget linked against OpenSSL/mbedTLS).

Usage:

  $arg0 [--dry-run] [--version X.X.X] [--edge] \\
        [--method detect|standalone|opkg] [--prefix /usr/local]

  --dry-run
      Echo the commands for the install process without running them.

  --version X.X.X
      Install a specific version instead of the latest.

  --edge
      Install the latest edge/pre-release version from GitHub.

  --method [detect | standalone | opkg]
      Choose the installation method. Defaults to detect.
      - detect: check for opkg first; fall back to standalone.
      - standalone: download a pre-built tar.gz from GitHub into <prefix>.
      - opkg: install via 'opkg install code-server' (feed must be configured).

  --prefix <dir>
      Installation prefix for the standalone method. Defaults to /usr/local.
      The archive is unpacked into <prefix>/lib/code-server-X.X.X and a
      symlink is created at <prefix>/bin/code-server.

Supported architectures for standalone releases: amd64 (x86_64), arm64 (aarch64).

Downloaded assets are cached under /tmp/code-server-cache (or
\$XDG_CACHE_HOME/code-server / \$HOME/.cache/code-server when set).
EOF
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------

echo_latest_version() {
  if [ "${EDGE-}" ]; then
    # Get the most recent release tag (including pre-releases) from the list.
    version="$(wget -qO- 'https://api.github.com/repos/coder/code-server/releases' \
      | grep '"tag_name"' \
      | head -n 1 \
      | awk -F '"' '{print $4}')"
  else
    # Use the /releases/latest endpoint which returns only stable releases.
    version="$(wget -qO- 'https://api.github.com/repos/coder/code-server/releases/latest' \
      | grep '"tag_name"' \
      | awk -F '"' '{print $4}')"
  fi
  # Strip leading 'v' if present.
  version="${version#v}"
  if [ -z "$version" ]; then
    echoerr "Failed to determine the latest code-server version."
    echoerr "Check your network/TLS configuration or pass --version X.X.X explicitly."
    exit 1
  fi
  echo "$version"
}

# ---------------------------------------------------------------------------
# Post-install messages
# ---------------------------------------------------------------------------

echo_standalone_postinstall() {
  echoh
  cat << EOF
Standalone release installed into $STANDALONE_INSTALL_PREFIX/lib/code-server-$VERSION

Add the bin directory to your PATH if it is not already present:
  export PATH="$STANDALONE_INSTALL_PREFIX/bin:\$PATH"

Then start code-server with:
  code-server

To expose to the network, edit ~/.config/code-server/config.yaml and set:
  bind-addr: 0.0.0.0:8080
EOF
}

echo_opkg_postinstall() {
  echoh
  cat << EOF
code-server installed via opkg.

Start code-server with:
  code-server

To start automatically at boot (SysVinit / procd), place a start script in
/etc/init.d/ or call code-server from your system's rc.local equivalent.
EOF
}

echo_coder_postinstall() {
  echoh
  echoh "Deploy code-server for your team with Coder: https://github.com/coder/coder"
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

main() {
  if [ "${TRACE-}" ]; then
    set -x
  fi

  unset DRY_RUN METHOD OPTIONAL ALL_FLAGS EDGE

  ALL_FLAGS=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -*) ALL_FLAGS="${ALL_FLAGS} $1" ;;
    esac

    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --method)
        METHOD="$(parse_arg "$@")"
        shift
        ;;
      --method=*)
        METHOD="$(parse_arg "$@")"
        ;;
      --prefix)
        STANDALONE_INSTALL_PREFIX="$(parse_arg "$@")"
        shift
        ;;
      --prefix=*)
        STANDALONE_INSTALL_PREFIX="$(parse_arg "$@")"
        ;;
      --version)
        VERSION="$(parse_arg "$@")"
        shift
        ;;
      --version=*)
        VERSION="$(parse_arg "$@")"
        ;;
      --edge)
        EDGE=1
        ;;
      -h | --h | -help | --help)
        usage
        exit 0
        ;;
      --)
        shift
        ALL_FLAGS="${ALL_FLAGS% --}"
        break
        ;;
      -*)
        echoerr "Unknown flag $1"
        echoerr "Run with --help to see usage."
        exit 1
        ;;
    esac

    shift
  done

  METHOD="${METHOD-detect}"
  if [ "$METHOD" != detect ] && [ "$METHOD" != standalone ] && [ "$METHOD" != opkg ]; then
    echoerr "Unknown install method \"$METHOD\""
    echoerr "Run with --help to see usage."
    exit 1
  fi

  # Verify wget is available – required for all methods except opkg-only.
  if [ "$METHOD" != opkg ] && ! command_exists wget; then
    echoerr "wget is required but was not found in PATH."
    echoerr "Please install wget with TLS support (e.g. add wget to your Yocto image)."
    exit 1
  fi

  CACHE_DIR="$(echo_cache_dir)"
  STANDALONE_INSTALL_PREFIX="${STANDALONE_INSTALL_PREFIX:-/usr/local}"
  VERSION="${VERSION:-$(echo_latest_version)}"
  OS="${OS:-$(os)}"
  ARCH="${ARCH:-$(arch)}"

  echoh "OS: $OS  ARCH: $ARCH  VERSION: $VERSION"
  echoh "Method: $METHOD"
  echoh

  # ---- Explicit method selection -------------------------------------------
  if [ "$METHOD" = opkg ]; then
    install_opkg
    echo_coder_postinstall
    exit 0
  fi

  if [ "$METHOD" = standalone ]; then
    if has_standalone; then
      install_standalone
      echo_coder_postinstall
      exit 0
    else
      echoerr "No pre-built standalone release available for architecture: $ARCH"
      echoerr "Supported: amd64 (x86_64), arm64 (aarch64)."
      echoerr "Try --method opkg if a suitable opkg feed is configured."
      exit 1
    fi
  fi

  # ---- Auto-detect ---------------------------------------------------------
  # Prefer opkg when it is available (native Yocto/OE package manager).
  if command_exists opkg; then
    echoh "Detected opkg. Attempting opkg installation."
    echoh "(If a code-server package is not in any configured feed, re-run with --method standalone.)"
    install_opkg
    echo_coder_postinstall
    exit 0
  fi

  # Fall back to the standalone GitHub release.
  if has_standalone; then
    echoh "opkg not found. Falling back to standalone release from GitHub."
    install_standalone
    echo_coder_postinstall
    exit 0
  fi

  echoerr "No suitable installation method found for architecture: $ARCH"
  echoerr "Supported standalone architectures: amd64, arm64."
  echoerr "Configure an opkg feed that includes code-server and retry with --method opkg."
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing helper
# ---------------------------------------------------------------------------

parse_arg() {
  case "$1" in
    *=*)
      opt="${1%%=*}"
      optarg="${1#*=}"
      if [ ! "$optarg" ] && [ ! "${OPTIONAL-}" ]; then
        echoerr "$opt requires an argument"
        echoerr "Run with --help to see usage."
        exit 1
      fi
      echo "$optarg"
      return
      ;;
  esac

  case "${2-}" in
    "" | -*)
      if [ ! "${OPTIONAL-}" ]; then
        echoerr "$1 requires an argument"
        echoerr "Run with --help to see usage."
        exit 1
      fi
      ;;
    *)
      echo "$2"
      return
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Download helper (wget, busybox-compatible)
# ---------------------------------------------------------------------------

fetch() {
  URL="$1"
  FILE="$2"

  if [ -e "$FILE" ]; then
    echoh "+ Reusing cached $FILE"
    return
  fi

  sh_c mkdir -p "$CACHE_DIR"
  # -O: write to file; incomplete download gets a temporary suffix so a partial
  # file is never mistaken for a complete one.
  sh_c wget -O '"'"$FILE.incomplete"'"' '"'"$URL"'"'
  sh_c mv '"'"$FILE.incomplete"'"' '"'"$FILE"'"'
}

# ---------------------------------------------------------------------------
# Install methods
# ---------------------------------------------------------------------------

install_opkg() {
  echoh "Installing code-server via opkg."
  echoh

  sh_c opkg update
  sh_c opkg install code-server

  echo_opkg_postinstall
}

install_standalone() {
  echoh "Installing code-server v$VERSION ($OS/$ARCH) from GitHub."
  echoh

  TARBALL="code-server-$VERSION-$OS-$ARCH.tar.gz"
  fetch \
    "https://github.com/coder/code-server/releases/download/v$VERSION/$TARBALL" \
    "$CACHE_DIR/$TARBALL"

  TARGET_DIR="$STANDALONE_INSTALL_PREFIX/lib/code-server-$VERSION"

  if [ -e "$TARGET_DIR" ]; then
    echoh
    echoh "code-server $VERSION is already installed at $TARGET_DIR"
    echoh "Remove that directory to reinstall."
    exit 0
  fi

  sh_c mkdir -p '"'"$STANDALONE_INSTALL_PREFIX/lib"'"' '"'"$STANDALONE_INSTALL_PREFIX/bin"'"'
  sh_c tar -C '"'"$STANDALONE_INSTALL_PREFIX/lib"'"' -xzf '"'"$CACHE_DIR/$TARBALL"'"'
  sh_c mv -f \
    '"'"$STANDALONE_INSTALL_PREFIX/lib/code-server-$VERSION-$OS-$ARCH"'"' \
    '"'"$TARGET_DIR"'"'
  sh_c ln -fs \
    '"'"$TARGET_DIR/bin/code-server"'"' \
    '"'"$STANDALONE_INSTALL_PREFIX/bin/code-server"'"'

  echo_standalone_postinstall
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

# Returns 0 (true) when a pre-built standalone release exists for $ARCH.
has_standalone() {
  case "$ARCH" in
    amd64 | arm64) return 0 ;;
    *) return 1 ;;
  esac
}

os() {
  uname_s="$(uname -s)"
  case "$uname_s" in
    Linux) echo linux ;;
    *) echo "$uname_s" ;;
  esac
}

# Normalise uname -m to the naming convention used by GitHub releases.
arch() {
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64)  echo amd64  ;;
    aarch64) echo arm64  ;;
    # Return as-is for other architectures (armv7l, mips, etc.) so callers
    # can report an unsupported-architecture error with the real name.
    *)       echo "$uname_m" ;;
  esac
}

# ---------------------------------------------------------------------------
# Shell execution helpers
# ---------------------------------------------------------------------------

command_exists() {
  if [ ! "$1" ]; then return 1; fi
  command -v "$@" > /dev/null 2>&1
}

# Print and optionally execute a command.
# Respects $DRY_RUN: when set, only prints without executing.
sh_c() {
  echoh "+ $*"
  if [ ! "${DRY_RUN-}" ]; then
    sh -c "$*"
  fi
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

echo_cache_dir() {
  if [ "${XDG_CACHE_HOME-}" ]; then
    echo "$XDG_CACHE_HOME/code-server"
  elif [ "${HOME-}" ]; then
    echo "$HOME/.cache/code-server"
  else
    echo "/tmp/code-server-cache"
  fi
}

# Print a message, replacing the literal $HOME path with '~' for readability.
echoh() {
  echo "$@" | humanpath
}

echoerr() {
  echoh "$@" >&2
}

humanpath() {
  if [ "${HOME-}" ]; then
    sed "s# $HOME# ~#g"
  else
    cat
  fi
}

# ---------------------------------------------------------------------------
main "$@"
