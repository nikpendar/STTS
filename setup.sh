#!/usr/bin/env bash
# Downloads the speech model's files from Hugging Face: Shenava Koochik 1.0, a streaming Core ML
# model (Reza2kn/Shenava-Koochik-1.0-CoreML-iOS15-fp16, Apache-2.0).
#
#   ./setup.sh           # the sidecars the app needs (tokenizer, features, manifest) into
#                        # PersianSTT/Models, and the model itself into build-model/Koochik.mlmodel,
#                        # which the app imports from Files (ModelImporter)
#   ./setup.sh bundle    # also compiles the model into the app (PersianSTT/Models/Koochik.mlmodelc,
#                        # 200 MB more in the IPA); needs Xcode
#   ./setup.sh sidecars  # the sidecars only
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

mkdir -p "$ROOT/build-model"
fetch "$NAME.mlmodel" "$ROOT/build-model/Koochik.mlmodel"
ls -l "$ROOT/build-model/Koochik.mlmodel"
[ "$MODE" = bundle ] || exit 0

rm -rf "$MODELS/Koochik.mlmodelc" "$ROOT/build-model/compiled"
xcrun coremlcompiler compile "$ROOT/build-model/Koochik.mlmodel" "$ROOT/build-model/compiled" \
  --deployment-target 15.0 --platform ios
mv "$ROOT/build-model/compiled/Koochik.mlmodelc" "$MODELS/"
du -sh "$MODELS/Koochik.mlmodelc"
