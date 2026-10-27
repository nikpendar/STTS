"""Fine-tunes a Persian encoder as a punctuation tagger on CPU for a fixed time budget, then exports it.

usage: train.py MODEL LAYERS MINUTES DATA OUT
LAYERS 0 keeps the model's depth; for ALBERT fewer layers only means fewer passes of the one shared layer
(same file size, less compute). Exports OUT/hf (transformers), OUT/model.onnx (fp32), OUT/model.int8.onnx,
OUT/traced.pt (TorchScript for Core ML conversion).
"""
import json, math, os, random, sys, time
import torch
from transformers import AutoConfig, AutoModelForTokenClassification, AutoTokenizer

name, layers, minutes, data, out = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5]
MAXLEN, BATCH = 128, 32
torch.manual_seed(0); random.seed(0)
torch.set_num_threads(os.cpu_count())

tok = AutoTokenizer.from_pretrained(name, use_fast=True)
cfg = AutoConfig.from_pretrained(name, num_labels=4)
if layers:
    cfg.num_hidden_layers = layers
model = AutoModelForTokenClassification.from_pretrained(name, config=cfg)
print("params", sum(p.numel() for p in model.parameters()), "layers", cfg.num_hidden_layers, flush=True)


def encode(words, labels=None):
    enc = tok(words, is_split_into_words=True, truncation=True, max_length=MAXLEN)
    ids = enc["input_ids"]
    wid = enc.word_ids()
    # The label sits on each word's last piece: the mark follows the word.
    last = {w: i for i, w in enumerate(wid) if w is not None}
    y = [-100] * len(ids)
    if labels is not None:
        for w, i in last.items():
            y[i] = labels[w]
    return ids, y, last


def load(path):
    return [json.loads(l) for l in open(path, encoding="utf-8")]


def batches(rows):
    random.shuffle(rows)
    for start in range(0, len(rows), BATCH * 50):
        block = sorted(rows[start:start + BATCH * 50], key=lambda r: len(r[0]))
        group = [block[i:i + BATCH] for i in range(0, len(block), BATCH)]
        random.shuffle(group)
        yield from group


def collate(group):
    n = max(len(ids) for ids, _ in group)
    ids = torch.tensor([i + [tok.pad_token_id] * (n - len(i)) for i, _ in group])
    mask = torch.tensor([[1] * len(i) + [0] * (n - len(i)) for i, _ in group])
    y = torch.tensor([l + [-100] * (n - len(l)) for _, l in group])
    return ids, mask, y


train = [encode(r["words"], r["labels"])[:2] for r in load(f"{data}/train.jsonl")]
print("train examples", len(train), flush=True)
opt = torch.optim.AdamW(model.parameters(), lr=5e-5, weight_decay=0.01)
total = [10_000]
sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, s / 300) * max(0.05, 1 - s / total[0]))
model.train()
start, step, seen, done = time.time(), 0, 0, False
while not done:
    for group in batches(train):
        ids, mask, y = collate(group)
        loss = model(input_ids=ids, attention_mask=mask, labels=y).loss
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step(); sched.step(); opt.zero_grad()
        step += 1; seen += len(group)
        elapsed = time.time() - start
        if step == 30:
            total[0] = int(minutes * 60 / (elapsed / 30))
            print("estimated steps", total[0], flush=True)
        if step % 100 == 0:
            print(f"step {step} seen {seen} loss {loss.item():.4f} {elapsed / 60:.1f} min", flush=True)
        if elapsed > minutes * 60:
            done = True
            break
print(f"trained {step} steps, {seen} examples ({seen / len(train):.2f} epochs)", flush=True)

model.eval()
os.makedirs(out, exist_ok=True)
model.save_pretrained(f"{out}/hf"); tok.save_pretrained(f"{out}/hf")


class Logits(torch.nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m

    def forward(self, input_ids, attention_mask):
        return self.m(input_ids=input_ids, attention_mask=attention_mask).logits


wrapped = Logits(model).eval()
ids = torch.tensor([encode("این یک جمله آزمایشی است که برای ساختن مدل نوشته شده".split())[0]])
mask = torch.ones_like(ids)
with torch.no_grad():
    torch.onnx.export(wrapped, (ids, mask), f"{out}/model.onnx", input_names=["input_ids", "attention_mask"],
                      output_names=["logits"], dynamic_axes={"input_ids": {0: "b", 1: "t"}, "attention_mask": {0: "b", 1: "t"},
                                                             "logits": {0: "b", 1: "t"}}, opset_version=17, dynamo=False)
    torch.jit.save(torch.jit.trace(wrapped, (ids, mask)), f"{out}/traced.pt")
from onnxruntime.quantization import QuantType, quantize_dynamic
quantize_dynamic(f"{out}/model.onnx", f"{out}/model.int8.onnx", weight_type=QuantType.QInt8,
                 op_types_to_quantize=["MatMul", "Gather", "Gemm"])
for f in ("model.onnx", "model.int8.onnx"):
    print(f, os.path.getsize(f"{out}/{f}"), flush=True)
