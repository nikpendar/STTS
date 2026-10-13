#!/usr/bin/env python3
"""Fine-tunes Shenava Koochik on the user's corrected dictations and exports the app's Core ML
model. Run by .github/workflows/train.yml on a GitHub runner (CPU).

    finetune.py --base koochik.nemo --samples <dir> --out <dir> [--fleurs <dir>]

<samples> holds <id>.wav (16 kHz mono) and <id>.json ({"id", "corrected", ...}), as the app
uploads them. A fixed tenth of them (by id) is held out to score the result; --fleurs adds
general Persian sentences (refs.tsv and WAVs) to check that the model did not get worse at
everything else. Writes <out>/Koochik-personal.mlmodel, <out>/heldout.tsv (held-out WAV and
reference) and <out>/summary.json. Every run starts again from the base model and trains on all
samples so far, so mistakes do not pile up from one version to the next.

Only the CTC path the app uses is trained, in the app's streaming mode (attention context
[70, 0]: 70 steps back, none ahead), with the lower encoder layers frozen and a small learning
rate, which keeps it close to the base model on a few hundred sentences.
"""
import argparse
import hashlib
import json
import math
import random
import re
import sys
import time
import wave
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from text import distance, normalize  # noqa: E402


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


def load_wav(path):
    with wave.open(str(path)) as f:
        assert f.getsampwidth() == 2 and f.getframerate() == 16000, f"{path.name}: need 16 kHz 16-bit WAV"
        audio = np.frombuffer(f.readframes(f.getnframes()), dtype=np.int16).astype(np.float32) / 32768
        if f.getnchannels() > 1:
            audio = audio.reshape(-1, f.getnchannels()).mean(axis=1)
    return audio


def is_held_out(sample_id):
    """A fixed tenth of the samples, so later runs are scored on the same held-out set."""
    return int(hashlib.sha1(sample_id.encode()).hexdigest(), 16) % 10 == 0


def load_samples(directory, max_seconds=30):
    samples, skipped = [], 0
    for meta_path in sorted(Path(directory).glob("*.json")):
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        wav = meta_path.with_suffix(".wav")
        text = normalize(meta.get("corrected", ""))
        if not wav.exists() or not text or re.search(r"\d", text):
            skipped += 1
            continue
        audio = load_wav(wav)
        if len(audio) > max_seconds * 16000 or len(audio) < 8000:
            skipped += 1
            continue
        samples.append({"id": meta.get("id", meta_path.stem), "wav": wav, "audio": audio, "text": text})
    return samples, skipped


def load_fleurs(directory, limit):
    directory = Path(directory)
    samples = []
    for line in open(directory / "refs.tsv", encoding="utf-8"):
        name, ref = line.rstrip("\n").split("\t", 1)
        text = normalize(ref)
        if text and not re.search(r"\d", text):
            samples.append({"id": name, "wav": directory / name, "audio": load_wav(directory / name), "text": text})
        if len(samples) >= limit:
            break
    return samples


def pad(batch):
    lengths = torch.tensor([len(s["audio"]) for s in batch])
    audio = torch.zeros(len(batch), int(lengths.max()))
    for i, s in enumerate(batch):
        audio[i, :len(s["audio"])] = torch.from_numpy(s["audio"])
    return audio, lengths


def forward(model, batch, augment=False):
    audio, lengths = pad(batch)
    features, feature_lengths = model.preprocessor(input_signal=audio, length=lengths)
    if augment and getattr(model, "spec_augmentation", None) is not None:
        features = model.spec_augmentation(input_spec=features, length=feature_lengths)
    encoded, encoded_lengths = model.encoder(audio_signal=features, length=feature_lengths)
    return model.ctc_decoder(encoder_output=encoded), encoded_lengths


def transcribe(model, samples, batch=4):
    """Greedy CTC, as the app decodes."""
    blank = model.ctc_decoder.num_classes_with_blank - 1
    texts = []
    model.eval()
    with torch.no_grad():
        for i in range(0, len(samples), batch):
            log_probs, lengths = forward(model, samples[i:i + batch])
            for row, length in zip(log_probs.argmax(-1), lengths):
                ids, previous = [], blank
                for k in row[:int(length)].tolist():
                    if k != previous and k != blank:
                        ids.append(k)
                    previous = k
                texts.append(model.tokenizer.ids_to_text(ids))
    return texts


def wer(model, samples):
    if not samples:
        return None
    errors = words = 0
    for sample, hypothesis in zip(samples, transcribe(model, samples)):
        ref = sample["text"].split()
        errors += distance(ref, normalize(hypothesis).split())
        words += len(ref)
    return round(100 * errors / max(words, 1), 2)


def train(model, samples, epochs, lr, batch, max_steps, train_layers, deadline):
    tokenizer = model.tokenizer
    blank = model.ctc_decoder.num_classes_with_blank - 1
    for p in model.parameters():
        p.requires_grad = False
    trained = list(model.encoder.layers[-train_layers:]) + [model.ctc_decoder]
    for module in trained:
        for p in module.parameters():
            p.requires_grad = True
    params = [p for p in model.parameters() if p.requires_grad]
    log(f"training {sum(p.numel() for p in params) / 1e6:.1f}M of {sum(p.numel() for p in model.parameters()) / 1e6:.1f}M parameters")
    optimizer = torch.optim.AdamW(params, lr=lr, weight_decay=1e-3, betas=(0.9, 0.98))
    steps_per_epoch = math.ceil(len(samples) / batch)
    total = min(max_steps, epochs * steps_per_epoch)
    warmup = max(1, total // 10)
    schedule = torch.optim.lr_scheduler.LambdaLR(
        optimizer, lambda s: min(1.0, (s + 1) / warmup) * 0.5 * (1 + math.cos(math.pi * min(s, total) / total)))
    targets = {s["id"]: tokenizer.text_to_ids(s["text"]) for s in samples}
    rng = random.Random(0)
    step = 0
    while step < total:
        order = samples[:]
        rng.shuffle(order)
        # Similar lengths together, so a batch is not mostly padding.
        chunks = [order[i:i + batch * 8] for i in range(0, len(order), batch * 8)]
        batches = []
        for chunk in chunks:
            chunk.sort(key=lambda s: len(s["audio"]))
            batches += [chunk[i:i + batch] for i in range(0, len(chunk), batch)]
        rng.shuffle(batches)
        running = 0.0
        for items in batches:
            if step >= total or time.time() > deadline:
                break
            model.eval()
            for module in trained:
                module.train()
            log_probs, lengths = forward(model, items, augment=True)
            ids = [targets[s["id"]] for s in items]
            loss = torch.nn.functional.ctc_loss(
                log_probs.transpose(0, 1), torch.tensor([k for row in ids for k in row]),
                lengths, torch.tensor([len(row) for row in ids]), blank=blank, reduction="mean", zero_infinity=True)
            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(params, 1.0)
            optimizer.step()
            schedule.step()
            step += 1
            running += loss.item()
            if step % 10 == 0:
                log(f"step {step}/{total}: loss {running / 10:.3f}")
                running = 0.0
        if time.time() > deadline:
            log("time budget reached")
            break
    model.eval()
    return step


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True, type=Path, help="the base .nemo checkpoint")
    parser.add_argument("--samples", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--fleurs", type=Path, help="general sentences to check against (refs.tsv + WAVs)")
    parser.add_argument("--fleurs-limit", type=int, default=40)
    parser.add_argument("--epochs", type=int, default=4)
    parser.add_argument("--lr", type=float, default=2e-5)
    parser.add_argument("--batch", type=int, default=4)
    parser.add_argument("--max-steps", type=int, default=600)
    parser.add_argument("--train-layers", type=int, default=6, help="top encoder layers trained, of 17")
    parser.add_argument("--minutes", type=float, default=240, help="time budget for training")
    parser.add_argument("--min-samples", type=int, default=10)
    args = parser.parse_args()
    started = time.time()
    torch.manual_seed(0)

    samples, skipped = load_samples(args.samples)
    log(f"{len(samples)} usable samples, {skipped} skipped")
    if len(samples) < args.min_samples:
        sys.exit(f"only {len(samples)} usable samples; need {args.min_samples}")
    held_out = [s for s in samples if is_held_out(s["id"])]
    if len(held_out) < 2:
        held_out = sorted(samples, key=lambda s: hashlib.sha1(s["id"].encode()).hexdigest())[:2]
    held_ids = {s["id"] for s in held_out}
    training = [s for s in samples if s["id"] not in held_ids]
    general = load_fleurs(args.fleurs, args.fleurs_limit) if args.fleurs else []
    log(f"{len(training)} training, {len(held_out)} held out, {len(general)} general sentences")

    import nemo.collections.asr as nemo_asr
    from export_coreml import export

    model = nemo_asr.models.ASRModel.restore_from(str(args.base), map_location="cpu")
    model.encoder.set_default_att_context_size([70, 0])
    model.eval()
    before = {"held_out": wer(model, held_out), "general": wer(model, general)}
    log(f"WER before: {before}")
    steps = train(model, training, args.epochs, args.lr, args.batch, args.max_steps, args.train_layers,
                  started + args.minutes * 60)
    after = {"held_out": wer(model, held_out), "general": wer(model, general)}
    log(f"WER after {steps} steps: {after}")

    args.out.mkdir(parents=True, exist_ok=True)
    with open(args.out / "heldout.tsv", "w", encoding="utf-8") as f:
        for s in held_out:
            f.write(f"{s['wav'].name}\t{s['text']}\n")
    shapes = export(model, args.out / "Koochik-personal.mlmodel")
    log(f"exported: {shapes}")
    summary = {"samples": len(samples), "training": len(training), "held_out": len(held_out), "steps": steps,
               "nemo_wer_before": before, "nemo_wer_after": after, "export": shapes,
               "minutes": round((time.time() - started) / 60, 1)}
    (args.out / "summary.json").write_text(json.dumps(summary, indent=1))
    log(json.dumps(summary))


if __name__ == "__main__":
    main()
