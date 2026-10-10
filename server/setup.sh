#!/usr/bin/env bash
# One-time setup of the training server on the Mac:
# Python packages, whisper.cpp's converter and quantizer, and the base model.
# Needs git and cmake: `xcode-select --install` and `brew install cmake`.
set -euo pipefail
cd "$(dirname "$0")"
BASE="${1:-farbodbij/whisper-medium-Persian}"

python3 -m venv .venv
. .venv/bin/activate
pip install -q -U pip
pip install -q torch transformers peft accelerate safetensors huggingface_hub numpy jiwer

if [ ! -d whisper.cpp ]; then
  git clone -q --depth 1 --branch v1.7.5 https://github.com/ggml-org/whisper.cpp
fi
# Without GGML_NATIVE=OFF, newer Apple clang stops on i8mm intrinsics in v1.7.5; only the
# converter's quantize step runs here, so native CPU tuning does not matter.
cmake -S whisper.cpp -B whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF -DGGML_NATIVE=OFF > /dev/null
cmake --build whisper.cpp/build -j > /dev/null
[ -d openai-whisper ] || git clone -q --depth 1 https://github.com/openai/whisper openai-whisper

mkdir -p data/base
TARGET="data/base/${BASE//\//--}"
[ -f "$TARGET/config.json" ] || python3 ../scripts/prepare_hf_model.py "$BASE" "$TARGET"
echo "Setup done. Start the server with: ./start.sh"
