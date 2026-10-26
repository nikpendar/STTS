#!/usr/bin/env bash
# Prepares a checkout for building in Xcode on a Mac (see docs/BUILD-MAC.md): the speech model's
# files and, with FONT_KEY set, the licensed app font.
#
#   ./scripts/mac-setup.sh           # sidecars into PersianSTT/Models, model into build-model/
#                                    # (imported once in the app from Files)
#   ./scripts/mac-setup.sh bundle    # also compiles the model into the app (no import, +200 MB)
#   FONT_KEY='…' ./scripts/mac-setup.sh
set -euo pipefail

MODE="${1:-model}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

xcodebuild -version || { echo "Xcode is missing: install Xcode 26 or newer from the App Store." >&2; exit 1; }

# From Hugging Face. Without it: copy Koochik.mlmodel into build-model/ and the four sidecar
# .json files (from any built KeylessShenava.ipa: Payload/PersianSTT.app/Models/) into
# PersianSTT/Models/ first; setup.sh skips files already there.
bash "$ROOT/setup.sh" model
# setup.sh skips files already there, so this only compiles.
[ "$MODE" = bundle ] && bash "$ROOT/setup.sh" bundle

# The font: the Copy App Font build phase puts build-font/AppFont.ttf into the app and keyboard.
if [ -n "${FONT_KEY:-}" ]; then
  OPENSSL="$(brew --prefix openssl@3 2>/dev/null || true)/bin/openssl"
  [ -x "$OPENSSL" ] || OPENSSL=openssl
  mkdir -p "$ROOT/build-font"
  "$OPENSSL" enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -pass env:FONT_KEY \
    -in "$ROOT/fonts/AppFont.ttf.enc" -out "$ROOT/build-font/AppFont.ttf"
  file "$ROOT/build-font/AppFont.ttf"
else
  echo "FONT_KEY is not set: the app will use the system font."
fi
echo "Ready: open PersianSTT.xcodeproj in Xcode."
