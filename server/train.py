#!/usr/bin/env python3
"""Fine-tunes the Persian Whisper model on the user's corrected dictations (data/samples) and
publishes a quantized ggml model (data/models) when it transcribes held-out samples better
than the base model.

Every run starts again from the base model and trains on all samples collected so far, so
mistakes do not pile up from one version to the next. LoRA adapters keep training light
enough for a Mac (Apple GPU through MPS) and limit how far the model drifts from the base.

    python3 train.py --data ./data [--epochs 3] [--force]
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
import wave
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
BASE = "farbodbij/whisper-medium-Persian"


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


def load_wav(path):
    with wave.open(str(path)) as f:
        assert f.getsampwidth() == 2 and f.getframerate() == 16000, f"{path}: need 16 kHz 16-bit WAV"
        audio = np.frombuffer(f.readframes(f.getnframes()), dtype=np.int16).astype(np.float32) / 32768
        if f.getnchannels() > 1:
            audio = audio.reshape(-1, f.getnchannels()).mean(axis=1)
    return audio


def normalize(text):
    """Spelling variants and punctuation should not count as recognition errors."""
    text = text.replace("ي", "ی").replace("ك", "ک").replace("‌", " ")
    text = re.sub(r"[^\w\s]", " ", text)
    return " ".join(text.split())


def is_eval(sample_id):
    """A fixed tenth of the samples, so later runs are scored on the same held-out set."""
    return int(hashlib.sha1(sample_id.encode()).hexdigest(), 16) % 10 == 0


def load_samples(samples_dir):
    """Whisper hears 30 s at a time, so longer recordings cannot be matched to their text."""
    samples = []
    for meta_path in sorted(samples_dir.glob("*.json")):
        meta = json.loads(meta_path.read_text())
        wav = meta_path.with_suffix(".wav")
        if wav.exists() and meta.get("corrected"):
            audio = load_wav(wav)
            if len(audio) <= 30 * 16000:
                samples.append({"id": meta["id"], "audio": audio, "text": meta["corrected"]})
    return samples


def ensure_base(base, data):
    """Downloads the base model once, with the tokenizer files whisper.cpp's converter needs."""
    if Path(base).is_dir():
        return Path(base)
    target = data / "base" / base.replace("/", "--")
    if not (target / "config.json").exists():
        log(f"downloading {base}")
        subprocess.check_call([sys.executable, str(HERE.parent / "scripts" / "prepare_hf_model.py"), base, str(target)])
    return target


def transcribe(model, processor, samples, device, batch=4):
    texts = []
    model.eval()
    with torch.no_grad():
        for i in range(0, len(samples), batch):
            chunk = samples[i:i + batch]
            features = processor.feature_extractor([s["audio"] for s in chunk], sampling_rate=16000,
                                                   return_tensors="pt").input_features.to(device)
            ids = model.generate(input_features=features, language="fa", task="transcribe", max_new_tokens=200)
            texts += processor.batch_decode(ids, skip_special_tokens=True)
    return texts


def wer(model, processor, samples, device):
    import jiwer
    hypotheses = [normalize(t) for t in transcribe(model, processor, samples, device)]
    references = [normalize(s["text"]) for s in samples]
    return 100 * jiwer.wer(references, hypotheses)


def train(model, processor, samples, device, epochs, lr, batch, accumulate):
    tokenizer = processor.tokenizer
    tokenizer.set_prefix_tokens(language="persian", task="transcribe")
    start_token = model.config.decoder_start_token_id
    optimizer = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=lr)
    model.train()
    model.config.use_cache = False
    step = 0
    for epoch in range(epochs):
        order = np.random.default_rng(epoch).permutation(len(samples))
        total = 0.0
        for i in range(0, len(order), batch):
            chunk = [samples[j] for j in order[i:i + batch]]
            features = processor.feature_extractor([s["audio"] for s in chunk], sampling_rate=16000,
                                                   return_tensors="pt").input_features.to(device)
            labels = []
            for s in chunk:
                ids = tokenizer(s["text"]).input_ids
                labels.append(ids[1:] if ids and ids[0] == start_token else ids)
            width = max(len(ids) for ids in labels)
            label_tensor = torch.full((len(labels), width), -100, dtype=torch.long)
            for row, ids in enumerate(labels):
                label_tensor[row, :len(ids)] = torch.tensor(ids)
            loss = model(input_features=features, labels=label_tensor.to(device)).loss / accumulate
            loss.backward()
            total += loss.item() * accumulate
            step += 1
            if step % accumulate == 0:
                optimizer.step()
                optimizer.zero_grad()
        optimizer.step()
        optimizer.zero_grad()
        log(f"epoch {epoch + 1}/{epochs}: loss {total / max(1, (len(order) + batch - 1) // batch):.3f}")
    model.config.use_cache = True


def convert(hf_dir, base_dir, out_path, quant):
    """HF checkpoint -> ggml (whisper.cpp converter) -> quantized ggml."""
    for name in ["vocab.json", "added_tokens.json", "merges.txt", "normalizer.json"]:
        if (base_dir / name).exists() and not (hf_dir / name).exists():
            shutil.copy(base_dir / name, hf_dir / name)
    config = json.loads((hf_dir / "config.json").read_text())
    config.setdefault("max_length", 448)
    (hf_dir / "config.json").write_text(json.dumps(config, indent=1))
    tmp = hf_dir / "ggml"
    tmp.mkdir(exist_ok=True)
    subprocess.check_call([sys.executable, str(HERE / "whisper.cpp" / "models" / "convert-h5-to-ggml.py"),
                           str(hf_dir), str(HERE / "openai-whisper"), str(tmp)])
    quantize = next(p for p in (HERE / "whisper.cpp" / "build" / "bin").glob("*quantize*") if p.is_file())
    subprocess.check_call([str(quantize), str(tmp / "ggml-model.bin"), str(out_path), quant])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", type=Path, default=HERE / "data")
    parser.add_argument("--base", default=BASE, help="Hugging Face repo id or local checkpoint")
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--batch", type=int, default=2)
    parser.add_argument("--accumulate", type=int, default=4)
    parser.add_argument("--lora-r", type=int, default=16)
    parser.add_argument("--quant", default="q4_0")
    parser.add_argument("--min-samples", type=int, default=10)
    parser.add_argument("--device", default="auto", help="auto, mps, cuda or cpu")
    parser.add_argument("--force", action="store_true", help="publish even if held-out WER did not improve")
    args = parser.parse_args()

    from peft import LoraConfig, get_peft_model
    from transformers import WhisperForConditionalGeneration, WhisperProcessor

    data = args.data.resolve()
    samples = load_samples(data / "samples")
    if len(samples) < args.min_samples:
        log(f"only {len(samples)} samples; need {args.min_samples}")
        return
    held_out = [s for s in samples if is_eval(s["id"])]
    if len(held_out) < 2:
        held_out = sorted(samples, key=lambda s: hashlib.sha1(s["id"].encode()).hexdigest())[:2]
    held_ids = {s["id"] for s in held_out}
    training = [s for s in samples if s["id"] not in held_ids]
    device = args.device if args.device != "auto" else (
        "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu")
    log(f"{len(training)} training and {len(held_out)} held-out samples on {device}")

    base_dir = ensure_base(args.base, data)
    processor = WhisperProcessor.from_pretrained(base_dir)
    model = WhisperForConditionalGeneration.from_pretrained(base_dir).to(device)
    before = wer(model, processor, held_out, device)
    log(f"held-out WER before: {before:.1f}%")

    # Recomputing activations in the backward pass keeps the medium model within a Mac's memory.
    model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    model = get_peft_model(model, LoraConfig(r=args.lora_r, lora_alpha=2 * args.lora_r, lora_dropout=0.05,
                                             target_modules=["q_proj", "v_proj"]))
    train(model, processor, training, device, args.epochs, args.lr, args.batch, args.accumulate)
    model = model.merge_and_unload()
    model.gradient_checkpointing_disable()
    after = wer(model, processor, held_out, device)
    log(f"held-out WER after: {after:.1f}%")
    if after >= before and not args.force:
        log("no improvement; keeping the current model")
        return

    models = data / "models"
    models.mkdir(parents=True, exist_ok=True)
    latest_path = models / "latest.json"
    version = (json.loads(latest_path.read_text())["version"] if latest_path.exists() else 0) + 1
    hf_dir = data / "work" / f"v{version}"
    shutil.rmtree(hf_dir, ignore_errors=True)
    model.to("cpu").save_pretrained(hf_dir)
    processor.save_pretrained(hf_dir)
    out = models / f"ggml-personal-v{version}.bin"
    convert(hf_dir, base_dir, out, args.quant)
    shutil.rmtree(hf_dir, ignore_errors=True)

    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    latest = {"version": version, "file": out.name, "size": out.stat().st_size, "sha256": digest,
              "wer_before": round(before, 1), "wer_after": round(after, 1), "samples": len(samples),
              "held_out": len(held_out), "base": args.base, "created": time.strftime("%Y-%m-%dT%H:%M:%S")}
    latest_path.write_text(json.dumps(latest, indent=1))
    for old in models.glob("ggml-personal-v*.bin"):
        if old != out and int(re.findall(r"\d+", old.stem)[-1]) < version - 1:
            old.unlink()
    log(f"published version {version}: {out.name}, {out.stat().st_size >> 20} MB")


if __name__ == "__main__":
    main()
