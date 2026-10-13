#!/usr/bin/env bash
# Public Persian sentences for the training workflow (FLEURS fa_ir dev split, 16 kHz PCM16):
#   fleurs-general/  the first 40, with refs.tsv: does a fine-tuned model still transcribe
#                    everyday Persian as well?
#   fleurs-samples/  the next 60 as the app uploads corrections (<id>.wav, <id>.json), for a
#                    test run of the workflow on data that is not private.
set -euo pipefail
base=https://huggingface.co/datasets/google/fleurs/resolve/main/data/fa_ir
curl -fsSL --retry 3 -o fleurs-dev.tsv "$base/dev.tsv"
curl -fsSL --retry 3 -o fleurs-dev.tar.gz "$base/audio/dev.tar.gz"
tar xzf fleurs-dev.tar.gz
mkdir -p fleurs-general fleurs-samples
n=0
while IFS=$'\t' read -r id file raw rest; do
  src="$(find dev -name "$file" | head -1)"
  [ -n "$src" ] || continue
  if [ $n -lt 40 ]; then
    python3 scripts/to_pcm16.py "$src" "fleurs-general/$file" > /dev/null
    printf '%s\t%s\n' "$file" "$raw" >> fleurs-general/refs.tsv
  else
    sample="fleurs-$id-$n"
    python3 scripts/to_pcm16.py "$src" "fleurs-samples/$sample.wav" > /dev/null
    python3 -c 'import json, sys; json.dump({"id": sys.argv[1], "original": "", "corrected": sys.argv[2]}, open(sys.argv[3], "w"), ensure_ascii=False)' \
      "$sample" "$raw" "fleurs-samples/$sample.json"
  fi
  n=$((n + 1))
  [ $n -lt 100 ] || break
done < fleurs-dev.tsv
rm -rf dev fleurs-dev.tar.gz
echo "$(ls fleurs-general/*.wav | wc -l) general sentences, $(ls fleurs-samples/*.wav | wc -l) test samples"
