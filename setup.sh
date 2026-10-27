#!/usr/bin/env bash
# Downloads the speech model's files: Shenava Koochik 1.0 (Reza2kn, Apache-2.0), a streaming Core ML
# model. The sidecars come from Hugging Face (Reza2kn/Shenava-Koochik-1.0-CoreML-iOS15-fp16); the
# model itself is the ML program with 8-bit weights that .github/workflows/model.yml publishes as
# the release koochik-mlp-int8 (Koochik.aar, 107 MB: half the size of the Hugging Face fp16
# NeuralNetwork, the same WER, less memory).
#
#   ./setup.sh           # the sidecars the app needs (tokenizer, features, manifest) into
#                        # PersianSTT/Models, and the model itself into build-model/Koochik.aar,
#                        # which the app imports from Files (ModelImporter)
#   ./setup.sh bundle    # also compiles the model into the app (PersianSTT/Models/Koochik.mlmodelc,
#                        # about 110 MB more in the IPA); needs Xcode
#   ./setup.sh sidecars  # the sidecars only
#
# Every mode also downloads the Persian voice and ONNX Runtime (see below).
#
# KOOCHIK_FORMAT=neuralnetwork takes the Hugging Face model instead (build-model/Koochik.mlmodel,
# 212 MB). There KOOCHIK_WEIGHTS=linear8 quantizes its weights to 8 bits (scripts/compress_model.py,
# 108 MB, the same WER), but a NeuralNetwork expands them again at load and needs more memory than
# fp16 (.github/workflows/compress-eval.yml); linear8 needs Python 3.9 or later and installs
# coremltools into build-model/venv.
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

# The Persian voice (release tts-fa-mana, from .github/workflows/tts-model.yml): the Mana Piper voice
# and the Homo-GE2PE phonemizer, both MahtaFetrat (MIT), 28 MB in the app (Models/Voice); and ONNX
# Runtime (MIT), which runs them, as Frameworks/onnxruntime.xcframework.
VOICE_RELEASE="${VOICE_RELEASE:-https://github.com/nikpendar/STTS/releases/download/tts-fa-mana}"
mkdir -p "$MODELS/Voice" "$ROOT/build-model" "$ROOT/Frameworks"
for f in g2p-encoder.onnx g2p-decoder.onnx mana.onnx mana.onnx.json; do
  if [ ! -s "$MODELS/Voice/$f" ]; then
    echo "Downloading $f"
    curl -fL --retry 3 --progress-bar "$VOICE_RELEASE/$f" -o "$MODELS/Voice/$f.part"
    mv "$MODELS/Voice/$f.part" "$MODELS/Voice/$f"
  fi
done
ORT_VERSION="${ORT_VERSION:-1.20.0}"
if [ ! -d "$ROOT/Frameworks/onnxruntime.xcframework" ]; then
  echo "Downloading ONNX Runtime $ORT_VERSION"
  curl -fL --retry 3 --progress-bar "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-$ORT_VERSION.zip" \
    -o "$ROOT/build-model/onnxruntime.zip"
  rm -rf "$ROOT/build-model/onnxruntime" && unzip -q "$ROOT/build-model/onnxruntime.zip" -d "$ROOT/build-model/onnxruntime"
  mv "$(find "$ROOT/build-model/onnxruntime" -name onnxruntime.xcframework -type d | head -n1)" "$ROOT/Frameworks/"
fi

[ "$MODE" = sidecars ] && exit 0

FORMAT="${KOOCHIK_FORMAT:-mlprogram}"
RELEASE="${KOOCHIK_RELEASE:-https://github.com/nikpendar/STTS/releases/download/koochik-mlp-int8}"
mkdir -p "$ROOT/build-model"
if [ "$FORMAT" = mlprogram ]; then
  MODEL="$ROOT/build-model/Koochik.aar"
  if [ ! -s "$MODEL" ]; then
    echo "Downloading Koochik.aar"
    curl -fL --retry 3 --progress-bar "$RELEASE/Koochik.aar" -o "$MODEL.part"
    mv "$MODEL.part" "$MODEL"
  fi
else
  MODEL="$ROOT/build-model/Koochik.mlmodel"
  WEIGHTS="${KOOCHIK_WEIGHTS:-fp16}"
  fetch "$NAME.mlmodel" "$ROOT/build-model/Koochik-fp16.mlmodel"
  if [ "$WEIGHTS" = fp16 ]; then
    cp "$ROOT/build-model/Koochik-fp16.mlmodel" "$MODEL"
  else
    VENV="$ROOT/build-model/venv"
    if [ ! -x "$VENV/bin/python" ]; then
      # coremltools has release wheels up to Python 3.13.
      PY="$(command -v python3.12 || command -v python3.13 || command -v python3.11 || command -v python3)"
      "$PY" -m venv "$VENV"
      "$VENV/bin/pip" install -q numpy
      "$VENV/bin/pip" install -q coremltools || "$VENV/bin/pip" install -q --pre coremltools
    fi
    rm -f "$MODEL"
    "$VENV/bin/python" "$ROOT/scripts/compress_model.py" "$ROOT/build-model/Koochik-fp16.mlmodel" \
      "$MODEL" "$WEIGHTS" 2>&1 | grep -E "^(before|after)" || true
    [ -s "$MODEL" ] || { echo "Compressing the model failed"; exit 1; }
  fi
fi
ls -l "$MODEL"
[ "$MODE" = bundle ] || exit 0

rm -rf "$MODELS/Koochik.mlmodelc" "$ROOT/build-model/compiled"
SOURCE="$MODEL"
if [ "$FORMAT" = mlprogram ]; then
  SOURCE="$ROOT/build-model/Koochik.mlpackage"
  rm -rf "$SOURCE" && mkdir -p "$SOURCE"
  aa extract -d "$SOURCE" -i "$MODEL"
fi
xcrun coremlcompiler compile "$SOURCE" "$ROOT/build-model/compiled" \
  --deployment-target 17.0 --platform ios
mv "$ROOT/build-model/compiled/Koochik.mlmodelc" "$MODELS/"
du -sh "$MODELS/Koochik.mlmodelc"
