#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# u — minimal terminal file manager — Linux installer
# Supports all major distros.
# ---------------------------------------------------------------------------

info()    { printf "\033[34m==>\033[0m %s\n" "$1"; }
ok()      { printf "\033[32m✓\033[0m %s\n" "$1"; }
warn()    { printf "\033[33m!\033[0m %s\n" "$1" >&2; }
fail()    { printf "\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    NAME="$ID"
    VERSION_ID="$VERSION_ID"
  else
    fail "cannot detect OS — /etc/os-release missing"
  fi

  # Determine package manager
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
    PKG_INSTALL="apt-get install -y"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_INSTALL="dnf install -y"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PKG_INSTALL="yum install -y"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
    PKG_INSTALL="zypper install -y"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PKG_INSTALL="apk add"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
    PKG_INSTALL="pacman -S --noconfirm"
  else
    PKG_MGR="unknown"
    PKG_INSTALL="true"  # fallback — user must install ruby manually
  fi
}

ensure_ruby() {
  if command -v ruby >/dev/null 2>&1; then
    ok "Ruby already installed: $(ruby -v)"
    return 0
  fi

  info "Ruby not found — installing via $PKG_MGR..."

  case "$PKG_MGR" in
    apt-get)
      # Try to install ruby-full; fall back to ruby if that fails
      if ! $PKG_INSTALL ruby-full 2>/dev/null; then
        if ! $PKG_INSTALL ruby 2>/dev/null; then
          fail "could not install Ruby with apt-get — please install Ruby manually"
        fi
      fi
      ;;
    dnf|yum)
      if ! $PKG_INSTALL ruby 2>/dev/null; then
        fail "could not install Ruby with $PKG_MGR — please install Ruby manually"
      fi
      ;;
    zypper)
      if ! $PKG_INSTALL ruby 2>/dev/null; then
        fail "could not install Ruby with $PKG_MGR — please install Ruby manually"
      fi
      ;;
    apk)
      if ! $PKG_INSTALL add ruby 2>/dev/null; then
        fail "could not install Ruby with apk — please install Ruby manually"
      fi
      ;;
    pacman)
      if ! $PKG_INSTALL -Sy --noconfirm ruby 2>/dev/null; then
        fail "could not install Ruby with pacman — please install Ruby manually"
      fi
      ;;
    *)
      fail "Ruby not found and package manager $PKG_MGR is unknown — please install Ruby $1"
  esac

  if ! command -v ruby >/dev/null 2>&1; then
    fail "Ruby installation seems to have failed — please verify and retry"
  fi
  ok "Ruby installed: $(ruby -v)"
}

ensure_curl() {
  if command -v curl >/dev/null 2>&1; then
    ok "curl already available"
    return 0
  fi

  warn "curl not found — attempting to install..."
  case "$PKG_MGR" in
    apt-get) $PKG_INSTALL curl ;;
    dnf|yum) $PKG_INSTALL curl ;;
    zypper) $PKG_INSTALL curl ;;
    apk) $PKG_INSTALL add curl ;;
    pacman) $PKG_INSTALL -Sy --noconfirm curl ;;
    *)
      fail "curl not found and cannot install with $PKG_MGR — please install curl manually"
  esac

  if ! command -v curl >/dev/null 2>&1; then
    fail "curl installation failed — please install curl manually and retry"
  fi
  ok "curl installed"
}

determine_dest() {
  USE_SUDO=""
  if [ -w "/usr/local/bin" ]; then
    DEST_DIR="/usr/local/bin"
  elif command -v sudo >/dev/null 2>&1; then
    # Test if sudo actually works (some envs require a terminal)
    if EDITOR=true sudo -n true 2>/dev/null; then
      DEST_DIR="/usr/local/bin"
      USE_SUDO="sudo"
    else
      DEST_DIR="$HOME/.local/bin"
      mkdir -p "$DEST_DIR"
    fi
  else
    DEST_DIR="$HOME/.local/bin"
    mkdir -p "$DEST_DIR"
  fi

  INSTALL_NAME="u"
  DEST_PATH="$DEST_DIR/$INSTALL_NAME"
}

main() {
  info "Starting u installation for Linux..."

  detect_distro
  ensure_curl
  ensure_ruby
  determine_dest

  info "Downloading u..."
  TMP_FILE="$(mktemp)"
  trap 'rm -f "$TMP_FILE"' EXIT

  # Fetch u.rb from the Linux branch
  SOURCE_URL="https://raw.githubusercontent.com/ufuayk/u/linux/u.rb"
  curl -fsSL "$SOURCE_URL" -o "$TMP_FILE" || fail "download failed."
  head -1 "$TMP_FILE" | grep -q "ruby" || fail "downloaded file doesn't look right — aborting."

  info "Installing to $DEST_PATH..."
  chmod 755 "$TMP_FILE"
  if [ -n "$USE_SUDO" ]; then
    $USE_SUDO mv "$TMP_FILE" "$DEST_PATH"
  else
    mv "$TMP_FILE" "$DEST_PATH"
  fi

  ok "u installed at $DEST_PATH"

  # Add to PATH if needed
  case ":$PATH:" in
    *":$DEST_DIR:"*) ;;
    *)
      echo
      warn "$DEST_DIR is not on your PATH."
      echo "  Add this to your shell profile (~/.zshrc or ~/.bashrc):"
      echo
      echo "    export PATH=\"$DEST_DIR:\$PATH\""
      echo
  esac

  echo
  ok "Done. Run 'u' to get started."
  # Super!
}

main "$@"