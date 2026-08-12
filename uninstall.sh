#!/usr/bin/env bash
set -euo pipefail

INSTALL_NAME="u"

info()  { printf "\033[34m==>\033[0m %s\n" "$1"; }
ok()    { printf "\033[32m✓\033[0m %s\n" "$1"; }
warn()  { printf "\033[33m!\033[0m %s\n" "$1"; }

if [ -f "/usr/local/bin/$INSTALL_NAME" ]; then
    DEST_PATH="/usr/local/bin/$INSTALL_NAME"
    USE_SUDO="sudo"
else
    DEST_PATH="$HOME/.local/bin/$INSTALL_NAME"
    USE_SUDO=""
fi

if [ -f "$DEST_PATH" ]; then
    info "Removing $DEST_PATH..."
    $USE_SUDO rm -f "$DEST_PATH"
    ok "u uninstalled successfully."
else
    warn "u is not installed in standard locations."
fi