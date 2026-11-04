#!/bin/bash
# Puts ML Kit's Persian handwriting files in a folder (default PersianSTTKeyboard/HandwritingModel),
# unzipped, under the names Handwriting.swift (BundledInkModel) reads: recospec, model, lm. These
# are the files ML Kit downloads itself for "fa" (its manifest.json and packmapping.pb), checked
# against the manifest's SHA-1. Not in git: build.yml and ink-eval.yml run this.
set -euo pipefail
OUT="${1:-PersianSTTKeyboard/HandwritingModel}"
BASE=https://dl.google.com/handwriting/models
mkdir -p "$OUT"
TMP="$(mktemp -d)"
fetch() { # name file sha1
  curl -fsSL --retry 4 -o "$TMP/$2.zip" "$BASE/$1"
  echo "$3  $TMP/$2.zip" | shasum -a 1 -c - > /dev/null
  rm -rf "$TMP/$2" && mkdir "$TMP/$2" && unzip -q "$TMP/$2.zip" -d "$TMP/$2"
  # One file in each.
  find "$TMP/$2" -type f -exec ls -S {} + | head -n1 | xargs -I{} mv {} "$OUT/$2"
}
fetch qrnn.fa.reco_20191215.fst_20191215.recospec.zip recospec ed4d43eaaaaa98df673f32c7b8de5bf7860bd2a3
fetch indy_lstm.arabic.5x272.tflite.20191215.zip model 4da245ca015d8f6f5e336421b93884314ff15f56
fetch fa.20191215.compact.fst.zip lm d72e97a2055b7a6af8f1073611aaacabba091f9a
ls -l "$OUT"
