#!/usr/bin/env bash
# Downloads the speech model's files from Hugging Face: Shenava Koochik 1.0, a streaming Core ML
# model (Reza2kn/Shenava-Koochik-1.0-CoreML-iOS15-fp16, Apache-2.0).
#
#   ./setup.sh           # the sidecars the app needs (tokenizer, features, manifest) into
#                        # PersianSTT/Models, and the model itself into build-model/Koochik.mlmodel,
#                        # which the app imports from Files (ModelImporter)
#   ./setup.sh bundle    # also compiles the model into the app (PersianSTT/Models/Koochik.mlmodelc,
#                        # 115 MB more in the IPA); needs Xcode
#   ./setup.sh sidecars  # the sidecars only
#
# The published model has fp16 weights (212 MB). By default they are quantized to 8 bits
# (scripts/compress_model.py linear8, 108 MB): the same WER on FLEURS and Common Voice
# (.github/workflows/compress-eval.yml). That needs Python 3.9 or later; it installs coremltools
# into build-model/venv. KOOCHIK_WEIGHTS=fp16 keeps the published weights.
set -euo pipefail

MODE="${1:-model}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="${SHENAVA_REPO:-Reza2kn/Shenava-Koochik-1.0-CoreML-iOS15-fp16}"
NAME=shenava_koochik_1_0_ctc_streaming_att70_0_ios15_fp16
BASE="https://huggingface.co/$REPO/resolve/main"
MODELS="$ROOT/PersianSTT/Models"
mkdir -p "$MODELS"

fetch() { # remote name, local path
  if [ ! -s "$2" ]; then
    echo "Downloading $1"
    curl -fL --retry 3 --progress-bar "$BASE/$1" -o "$2.part"
    mv "$2.part" "$2"
  fi
}

fetch tokens.json "$MODELS/tokens.json"
fetch preprocessor.json "$MODELS/preprocessor.json"
fetch mel_filters_slaney_80x257.json "$MODELS/mel_filters_slaney_80x257.json"
fetch "${NAME}_manifest.json" "$MODELS/manifest.json"
[ "$MODE" = sidecars ] && exit 0

WEIGHTS="${KOOCHIK_WEIGHTS:-linear8}"
mkdir -p "$ROOT/build-model"
fetch "$NAME.mlmodel" "$ROOT/build-model/Koochik-fp16.mlmodel"
if [ "$WEIGHTS" = fp16 ]; then
  cp "$ROOT/build-model/Koochik-fp16.mlmodel" "$ROOT/build-model/Koochik.mlmodel"
else
  VENV="$ROOT/build-model/venv"
  if [ ! -x "$VENV/bin/python" ]; then
    # coremltools has release wheels up to Python 3.13.
    PY="$(command -v python3.12 || command -v python3.13 || command -v python3.11 || command -v python3)"
    "$PY" -m venv "$VENV"
    "$VENV/bin/pip" install -q numpy
    "$VENV/bin/pip" install -q coremltools || "$VENV/bin/pip" install -q --pre coremltools
  fi
  rm -f "$ROOT/build-model/Koochik.mlmodel"
  "$VENV/bin/python" "$ROOT/scripts/compress_model.py" "$ROOT/build-model/Koochik-fp16.mlmodel" \
    "$ROOT/build-model/Koochik.mlmodel" "$WEIGHTS" 2>&1 | grep -E "^(before|after)" || true
  [ -s "$ROOT/build-model/Koochik.mlmodel" ] || { echo "Compressing the model failed"; exit 1; }
fi
ls -l "$ROOT/build-model/Koochik.mlmodel"
[ "$MODE" = bundle ] || exit 0

rm -rf "$MODELS/Koochik.mlmodelc" "$ROOT/build-model/compiled"
xcrun coremlcompiler compile "$ROOT/build-model/Koochik.mlmodel" "$ROOT/build-model/compiled" \
  --deployment-target 15.0 --platform ios
mv "$ROOT/build-model/compiled/Koochik.mlmodelc" "$MODELS/"
du -sh "$MODELS/Koochik.mlmodelc"
