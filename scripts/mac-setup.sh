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
BACKUP="https://github.com/nikpendar/STTS/releases/download/backup-2026-10-26"
MODELS="$ROOT/PersianSTT/Models"

xcodebuild -version || { echo "Xcode is missing: install Xcode 26 or newer from the App Store." >&2; exit 1; }

# Hugging Face first; the copy in the backup release when that fails.
if ! bash "$ROOT/setup.sh" model; then
  echo "Hugging Face failed; using the backup release."
  mkdir -p "$MODELS" "$ROOT/build-model"
  for name in tokens.json preprocessor.json mel_filters_slaney_80x257.json manifest.json; do
    [ -s "$MODELS/$name" ] || curl -fL --retry 3 "$BACKUP/$name" -o "$MODELS/$name"
  done
  [ -s "$ROOT/build-model/Koochik.mlmodel" ] || \
    curl -fL --retry 3 --progress-bar "$BACKUP/Koochik.mlmodel" -o "$ROOT/build-model/Koochik.mlmodel"
fi
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
