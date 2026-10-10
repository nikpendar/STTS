#!/usr/bin/env bash
# Downloads whisper.xcframework (whisper.cpp) and a ggml Whisper model into the project.
#
#   ./setup.sh                 # default: base-q5_1  (~57 MB, smallest usable for Persian)
#   ./setup.sh small-q5_1      # ~181 MB, noticeably better Persian
#   ./setup.sh large-v3-turbo-q5_0   # ~547 MB, best quality, needs iPhone 13 or newer
#   ./setup.sh none            # framework only; the app then imports its model from Files
set -euo pipefail

MODEL="${1:-base-q5_1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="$ROOT/Frameworks"
MODEL_DIR="$ROOT/PersianSTT/Models"
mkdir -p "$FW_DIR" "$MODEL_DIR"

if [ ! -d "$FW_DIR/whisper.xcframework" ]; then
  echo "Finding latest whisper.cpp release..."
  AUTH=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
  # Newest release that ships an xcframework asset (not every release does).
  URL="$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} "https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=20" \
    | python3 -c 'import json,sys
for r in json.load(sys.stdin):
    for a in r.get("assets", []):
        if a["name"].endswith("xcframework.zip"):
            print(a["browser_download_url"]); sys.exit()' || true)"
  if [ -z "$URL" ]; then
    echo "Could not find an xcframework asset in the latest whisper.cpp release." >&2
    exit 1
  fi
  echo "Downloading $URL"
  TMP="$(mktemp -d)"
  curl -fL --progress-bar "$URL" -o "$TMP/whisper.zip"
  unzip -q "$TMP/whisper.zip" -d "$TMP/unzipped"
  SRC="$(find "$TMP/unzipped" -type d -name whisper.xcframework | head -n1)"
  if [ -z "$SRC" ]; then
    echo "whisper.xcframework not found inside the downloaded zip." >&2
    exit 1
  fi
  cp -R "$SRC" "$FW_DIR/"
  rm -rf "$TMP"
  echo "Installed Frameworks/whisper.xcframework"
else
  echo "Frameworks/whisper.xcframework already present."
fi

if [ "$MODEL" = none ]; then
  echo "No model downloaded."
  exit 0
fi

# Only one model is kept in the app bundle; the app uses the first .bin it finds.
TARGET="$MODEL_DIR/ggml-$MODEL.bin"
if [ ! -f "$TARGET" ]; then
  find "$MODEL_DIR" -name 'ggml-*.bin' -delete
  echo "Downloading model ggml-$MODEL.bin ..."
  curl -fL --progress-bar "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin" -o "$TARGET.part"
  mv "$TARGET.part" "$TARGET"
fi
echo "Model: $(du -h "$TARGET" | cut -f1)  $TARGET"
echo "Done. Open PersianSTT.xcodeproj in Xcode."
