#!/bin/zsh
# Build NozomiFlow.app (displayed as "Nozomi Flow") from the SwiftPM executable.
# Usage: scripts/bundle.sh [debug|release] [--open]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONF="${1:-release}"

swift build -c "$CONF"

BIN=".build/$CONF/NozomiFlow"
APP="$ROOT/build/NozomiFlow.app"

# Stop a running instance so codesign/TCC see a clean slate.
pkill -x NozomiFlow 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NozomiFlow"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Support/AppIcon.icns" ]; then
  cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Prefer a stable Apple Development identity so TCC grants survive rebuilds.
# Selected by SHA-1 rather than by name: the keychain can hold several certificates
# with the identical display name, and codesign rejects a name that matches more
# than one as ambiguous.
# Override with SIGN_IDENTITY to pick a specific certificate.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/{print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" \
  --entitlements "$ROOT/Support/NozomiFlow.entitlements" \
  "$APP"

echo "Built: $APP"
echo "Signed as: $IDENTITY"

if [[ "${2:-}" == "--open" ]]; then
  open "$APP"
fi
