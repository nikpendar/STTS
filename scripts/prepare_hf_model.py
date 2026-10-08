#!/usr/bin/env python3
"""Downloads a Hugging Face Whisper fine-tune and fills in what whisper.cpp's
convert-h5-to-ggml.py expects: vocab.json, added_tokens.json and max_length.
Missing tokenizer files are taken from the OpenAI model of the same architecture.

Usage: prepare_hf_model.py <repo id> <out dir>
"""
import json
import os
import sys

from huggingface_hub import hf_hub_download, snapshot_download

repo, out = sys.argv[1:]
snapshot_download(repo, local_dir=out, ignore_patterns=["*/*", "*.msgpack", "*.h5", "*.ot", "*.onnx", "optimizer*", "training_args*"])
config_path = os.path.join(out, "config.json")
config = json.load(open(config_path))

if config["d_model"] == 1280:
    base = "openai/whisper-large-v3-turbo" if config["decoder_layers"] == 4 else (
        "openai/whisper-large-v3" if config["num_mel_bins"] == 128 else "openai/whisper-large-v2")
else:
    base = {384: "openai/whisper-tiny", 512: "openai/whisper-base", 768: "openai/whisper-small",
            1024: "openai/whisper-medium"}[config["d_model"]]
print(f"{repo}: d_model={config['d_model']} decoder_layers={config['decoder_layers']} mels={config['num_mel_bins']} -> tokenizer base {base}")

for name in ["vocab.json", "added_tokens.json", "merges.txt", "normalizer.json"]:
    if not os.path.exists(os.path.join(out, name)):
        try:
            hf_hub_download(base, name, local_dir=out)
            print(f"copied {name} from {base}")
        except Exception as error:  # merges/normalizer are optional
            print(f"could not copy {name}: {error}")

if "max_length" not in config:
    config["max_length"] = 448
    json.dump(config, open(config_path, "w"), indent=1)
