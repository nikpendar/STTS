# Stage 3 of the dictation-correction student: Qwen3 (1.7B by default, Apache-2.0) with LoRA learns
# "[style]\n<dictation>" -> text in that style, from the teacher's versions (kaggle/rw-teach). Styles:
# [فقط اصلاح] fix (default), [رسمی] formal, [خودمانی] casual, [خلاصه] summary. Teacher outputs that add
# numbers or Latin text, have odd lengths, or whose fix changes the words of the correct text are left
# out; Wikipedia rows learn fix from the sentence itself. Evaluation on held-out speech (FLEURS test +
# a tenth of CV test): fix -> word error vs the correct text before/after; every style -> chrF vs the
# teacher, numbers kept, samples. Output: /kaggle/working/{adapter/, eval.jsonl, summary.txt}.
import glob, json, math, os, random, re, subprocess, sys, time, unicodedata

subprocess.run("pip install -q peft sacrebleu 2>&1 | tail -1", shell=True)
import torch
from peft import LoraConfig, get_peft_model
from sacrebleu.metrics import CHRF
from transformers import AutoModelForCausalLM, AutoTokenizer

T0 = time.time()
BASE = os.environ.get("BASE", "Qwen/Qwen3-1.7B")
TRAIN_H = float(os.environ.get("TRAIN_H", "8.0"))
EVAL_N = int(os.environ.get("EVAL_N", "300"))
OUT = "/kaggle/working"
STYLES = {"fix": "فقط اصلاح", "formal": "رسمی", "casual": "خودمانی", "summary": "خلاصه"}
random.seed(5)
torch.manual_seed(5)


def log(*a):
    print(f"[{(time.time() - T0) / 3600:5.2f} h]", *a, flush=True)


def plain(t):
    """Letters only: no spaces, ZWNJ, diacritics or marks (for 'same words' checks)."""
    t = unicodedata.normalize("NFKC", t).replace("ي", "ی").replace("ك", "ک").replace("ة", "ه")
    t = re.sub("[ً-ْٰٔـ]", "", t)
    return re.sub(r"[\W_]", "", t)


def words(t):
    t = unicodedata.normalize("NFKC", t).replace("ي", "ی").replace("ك", "ک").replace("\u200c", " ")  # Shenava writes a space for ZWNJ
    t = re.sub("[ً-ْٰٔـ]", "", t)
    return re.sub(r"[^\w\s]|_", " ", t).split()


def dist(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def nums(t):
    t = t.translate(str.maketrans("۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩", "01234567890123456789"))
    return set(re.findall(r"\d+", t))


COLLOQUIAL = [" رو ", " رو.", "می‌تون", "نمی‌تون", "می‌خوای", "می‌خوام", " یه ", "کوچیک", " دیگه "]


def ok(style, out, ref):
    if not out or len(out) > 3 * len(ref) + 40:
        return False
    if not nums(out) <= nums(ref) or (re.search("[A-Za-z]", out) and not re.search("[A-Za-z]", ref)):
        return False
    r = len(out) / max(len(ref), 1)
    padded = f" {out} "
    if style in ("formal", "summary") and any(m in padded for m in COLLOQUIAL):
        return False  # the teacher sometimes slips into spoken forms; summary is written Persian
    if style == "casual" and " را " in padded:
        return False
    if style == "fix":
        a, b = plain(out), plain(ref)
        return dist(a, b) <= max(1, 0.04 * len(b))
    if style == "summary":
        return 0.2 <= r <= 1.1
    return 0.5 <= r <= 1.8


path = glob.glob("/kaggle/input/**/teach.jsonl", recursive=True)
if not path:
    sys.exit("teach.jsonl not found")
recs = [json.loads(l) for l in open(path[0], encoding="utf-8")]
train, held, kept, dropped = [], [], {k: 0 for k in STYLES}, {k: 0 for k in STYLES}
for r in recs:
    if r["src"] == "wiki":
        r["fix"] = r["ref"]
    if len(r["ref"].split()) < 8 and ok("fix", r["fix"], r["ref"]):
        r["summary"] = r["fix"]  # short sentences: a "summary" only invites made-up changes
    if r["split"] == "heldout":
        held.append(r)
        continue
    for k in STYLES:
        if ok(k, r[k], r["ref"]):
            train.append((k, r["hyp"], r[k]))
            kept[k] += 1
        else:
            dropped[k] += 1
random.shuffle(train)
log(f"{len(recs)} teacher rows, {len(train)} training examples, kept {kept}, dropped {dropped}, held out {len(held)}")

tok = AutoTokenizer.from_pretrained(BASE)
tok.padding_side = "left"


def prompt(style, text):
    return tok.apply_chat_template([{"role": "user", "content": f"[{STYLES[style]}]\n{text}"}], tokenize=False,
                                   add_generation_prompt=True, enable_thinking=False)


def encode(style, src, tgt):
    p = tok(prompt(style, src), add_special_tokens=False)["input_ids"]
    t = tok(tgt + "<|im_end|>", add_special_tokens=False)["input_ids"]
    ids = (p + t)[:384]
    return ids, ([-100] * len(p) + t)[:384]


data = [encode(*x) for x in train]
model = AutoModelForCausalLM.from_pretrained(BASE, torch_dtype=torch.float16).cuda()
model.gradient_checkpointing_enable()
model.enable_input_require_grads()
model = get_peft_model(model, LoraConfig(r=32, lora_alpha=64, lora_dropout=0.05, task_type="CAUSAL_LM",
                                         target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]))
for p in model.parameters():
    if p.requires_grad:
        p.data = p.data.float()
model.print_trainable_parameters()

MB, ACC, LR = 8, 2, 2e-4
# Batches of similar length, shuffled.
order = sorted(range(len(data)), key=lambda i: len(data[i][0]))
batches = [order[i:i + MB] for i in range(0, len(order), MB)]
random.shuffle(batches)
steps = len(batches) // ACC
opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=LR, weight_decay=0.0)
sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1, (s + 1) / 100) * 0.5 * (1 + math.cos(math.pi * min(s, steps) / steps)))
scaler = torch.amp.GradScaler()
model.train()
deadline = T0 + TRAIN_H * 3600
done, loss_sum = 0, 0.0
for bi, b in enumerate(batches):
    if time.time() > deadline:
        log("time budget reached")
        break
    n = max(len(data[i][0]) for i in b)
    ids = torch.full((len(b), n), tok.pad_token_id)
    lab = torch.full((len(b), n), -100)
    att = torch.zeros((len(b), n), dtype=torch.long)
    for j, i in enumerate(b):
        x, y = data[i]
        ids[j, :len(x)], lab[j, :len(y)], att[j, :len(x)] = torch.tensor(x), torch.tensor(y), 1
    with torch.autocast("cuda", dtype=torch.float16):
        loss = model(input_ids=ids.cuda(), attention_mask=att.cuda(), labels=lab.cuda()).loss / ACC
    scaler.scale(loss).backward()
    loss_sum += loss.item()
    if (bi + 1) % ACC == 0:
        scaler.unscale_(opt)
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        scaler.step(opt)
        scaler.update()
        opt.zero_grad(set_to_none=True)
        sched.step()
        done += 1
        if done % 200 == 0:
            log(f"step {done}/{steps} loss {loss_sum / 200:.3f}")
            loss_sum = 0.0
log(f"trained {done}/{steps} steps")
model.save_pretrained(f"{OUT}/adapter")
tok.save_pretrained(f"{OUT}/adapter")

# --- evaluation on held-out speech
model.eval()
model.gradient_checkpointing_disable()
model.config.use_cache = True
random.shuffle(held)
held = held[:EVAL_N]
chrf = CHRF(word_order=2)
results = {k: [] for k in STYLES}
t = time.time()
for k in STYLES:
    for i in range(0, len(held), 24):
        chunk = held[i:i + 24]
        enc = tok([prompt(k, r["hyp"]) for r in chunk], return_tensors="pt", padding=True, add_special_tokens=False).to("cuda")
        with torch.no_grad(), torch.autocast("cuda", dtype=torch.float16):
            gen = model.generate(**enc, max_new_tokens=200, do_sample=False, pad_token_id=tok.pad_token_id)
        for r, g in zip(chunk, gen[:, enc["input_ids"].shape[1]:]):
            results[k].append((r, tok.decode(g, skip_special_tokens=True).strip()))
gen_s = (time.time() - t) / (len(held) * len(STYLES))

lines = [f"base {BASE}, {done}/{steps} steps, {len(train)} examples, kept {kept}, dropped {dropped}",
         f"held out sentences evaluated: {len(held)}, generation {gen_s * 1000:.0f} ms per sentence (batched, T4)"]
with open(f"{OUT}/eval.jsonl", "w", encoding="utf-8") as f:
    for k, rs in results.items():
        for r, o in rs:
            f.write(json.dumps({"style": k, "id": r["id"], "hyp": r["hyp"], "ref": r["ref"], "teacher": r[k], "student": o},
                               ensure_ascii=False) + "\n")
ref_words = sum(len(words(r["ref"])) for r, _ in results["fix"])
before = sum(dist(words(r["ref"]), words(r["hyp"])) for r, _ in results["fix"])
after = sum(dist(words(r["ref"]), words(o)) for r, o in results["fix"])
teacher_fix = sum(dist(words(r["ref"]), words(r["fix"])) for r, _ in results["fix"])
lines.append(f"[fix] word errors vs correct text (ZWNJ counted as a space, marks ignored): Shenava {100 * before / ref_words:.1f}% -> "
             f"student {100 * after / ref_words:.1f}% (teacher's fix of the correct text {100 * teacher_fix / ref_words:.1f}%)")
for k, rs in results.items():
    score = chrf.corpus_score([o for _, o in rs], [[r[k] for r, _ in rs]]).score
    base_score = chrf.corpus_score([r["hyp"] for r, _ in rs], [[r[k] for r, _ in rs]]).score
    numbers = sum(nums(o) <= nums(r["ref"]) for r, o in rs) / len(rs)
    ratio = sum(len(o) for _, o in rs) / max(1, sum(len(r[k]) for r, _ in rs))
    lines.append(f"[{k}] chrF++ vs teacher {score:.1f} (Shenava text as is {base_score:.1f}), no new numbers {100 * numbers:.0f}%, "
                 f"length vs teacher {ratio:.2f}")
lines.append("--- samples")
for k, rs in results.items():
    lines.append(f"\n=== [{STYLES[k]}]")
    for r, o in rs[:6]:
        lines += [f"شنوا: {r['hyp']}", f"شاگرد: {o}", f"معلم: {r[k]}", f"درست: {r['ref']}", ""]
lines.append(f"hours {(time.time() - T0) / 3600:.1f}")
open(f"{OUT}/summary.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
