set -euo pipefail

SOURCE_URL="https://raw.githubusercontent.com/ufuayk/u/main/u.rb"
INSTALL_NAME="u"

info()  { printf "\033[34m==>\033[0m %s\n" "$1"; }
ok()    { printf "\033[32m✓\033[0m %s\n" "$1"; }
fail()  { printf "\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

command -v ruby >/dev/null 2>&1 || fail "ruby not found. macOS ships Ruby by default — check your PATH."
command -v curl >/dev/null 2>&1 || fail "curl is required to install u."

USE_SUDO=""
if [ -w "/usr/local/bin" ]; then
  DEST_DIR="/usr/local/bin"
elif command -v sudo >/dev/null 2>&1; then
  DEST_DIR="/usr/local/bin"
  USE_SUDO="sudo"
else
  DEST_DIR="$HOME/.local/bin"
  mkdir -p "$DEST_DIR"
fi

DEST_PATH="$DEST_DIR/$INSTALL_NAME"

info "Downloading u..."
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

curl -fsSL "$SOURCE_URL" -o "$TMP_FILE" || fail "download failed."
head -1 "$TMP_FILE" | grep -q "ruby" || fail "downloaded file doesn't look right — aborting."

info "Installing to $DEST_PATH..."
chmod 755 "$TMP_FILE"
$USE_SUDO mv "$TMP_FILE" "$DEST_PATH"

ok "u installed at $DEST_PATH"

case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *)
    echo
    printf "\033[33m!\033[0m %s is not on your PATH.\n" "$DEST_DIR"
    echo "  Add this to your shell profile (~/.zshrc or ~/.bashrc):"
    echo
    echo "    export PATH=\"$DEST_DIR:\$PATH\""
    echo
    ;;
esac

echo
ok "Done. Run 'u' to get started."