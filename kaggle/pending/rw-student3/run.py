# Stage 3 of the dictation-correction student: Qwen3 (1.7B by default, Apache-2.0) with LoRA learns
# "[style]\n<dictation>" -> text in that style, from the teacher's versions (kaggle/rw-teach). Styles:
# [فقط اصلاح] fix (default), [رسمی] formal, [خودمانی] casual, [خلاصه] summary. Teacher outputs that add
# numbers or Latin text, have odd lengths, or whose fix changes the words of the correct text are left
# out; Wikipedia rows learn fix from the sentence itself. Evaluation on held-out speech (FLEURS test +
# a tenth of CV test): fix -> word error vs the correct text before/after; every style -> chrF vs the
# teacher, numbers kept, samples. Round 2 also reads kaggle/rw-teach2 (dictated messages with
# self-corrections, Wikipedia paragraphs) and scores each held-out set (asr, mono, para) separately.
# Round 3 reads kaggle/rw-teach3 instead of rw-teach (round-1 sentences rewritten with better rules,
# plus real errors on CV train/other and phone-like degraded audio), adds the degraded held-out set
# (noisy) and reports fix with a guard: when the output strays too far from the input with no
# self-correction in it, or brings in Latin text, the input is kept as it is.
# Also scores the teacher-made disfluent dictation (fillers, restarts, unmarked rephrasing) as set disfl.
# Output: /kaggle/working/{adapter/, eval.jsonl, summary.txt}.
import glob, json, math, os, random, re, subprocess, sys, time, unicodedata

# The image's torchao is older than peft accepts, and LoRA here does not need it.
subprocess.run("pip uninstall -y -q torchao; pip install -q peft sacrebleu 2>&1 | tail -1", shell=True)
import torch
from peft import LoraConfig, get_peft_model
from sacrebleu.metrics import CHRF
from transformers import AutoModelForCausalLM, AutoTokenizer

T0 = time.time()
BASE = os.environ.get("BASE", "Qwen/Qwen3-1.7B")
TRAIN_H = float(os.environ.get("TRAIN_H", "8.0"))
MAX_TRAIN = int(os.environ.get("MAX_TRAIN", "120000"))
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


paths = sorted(glob.glob("/kaggle/input/**/teach3.jsonl", recursive=True) + glob.glob("/kaggle/input/**/teach2.jsonl", recursive=True))
if not paths:
    sys.exit("no teacher data found")
recs = [json.loads(l) for p in paths for l in open(p, encoding="utf-8")]
log("teacher files", paths)
train, held, kept, dropped = [], {"asr": [], "noisy": [], "disfl": [], "mono": [], "para": []}, {k: 0 for k in STYLES}, {k: 0 for k in STYLES}
for r in recs:
    if r["src"] == "wiki":
        r["fix"] = r["ref"]
    if len(r["ref"].split()) < 8 and ok("fix", r["fix"], r["ref"]):
        r["summary"] = r["fix"]  # short sentences: a "summary" only invites made-up changes
    if r["split"] == "heldout":
        held[r["src"]].append(r)
        continue
    for k in STYLES:
        if ok(k, r[k], r["ref"]):
            train.append((k, r["hyp"], r[k]))
            kept[k] += 1
        else:
            dropped[k] += 1

# Self-corrections («ساعت پنج نه ببخشید شش»): the speaker first says a wrong value of the same kind
# (number, day, month, time of day, city, name), then the right one. Built from round-1 rows: the
# wrong value and a correction phrase go into Shenava's text before a word of that kind; every
# target stays as it was. Held-out speech rows get the same treatment for the self-correction test.
KIND_WORDS = [
    "یک دو سه چهار پنج شش هفت هشت نه ده یازده دوازده سیزده چهارده پانزده شانزده هفده هجده نوزده بیست سی چهل پنجاه شصت هفتاد هشتاد نود صد دویست سیصد پانصد هزار".split(),
    "شنبه یکشنبه دوشنبه چهارشنبه پنجشنبه جمعه".split(),
    "فروردین اردیبهشت خرداد تیر مرداد شهریور مهر آبان آذر دی بهمن اسفند ژانویه فوریه مارس آوریل مه ژوئن ژوئیه اوت سپتامبر اکتبر نوامبر دسامبر".split(),
    "صبح ظهر عصر شب".split(),
    "تهران مشهد اصفهان شیراز تبریز کرج اهواز قم رشت یزد کرمان همدان ارومیه زاهدان ساری".split(),
    "علی رضا محمد حسین مریم سارا زهرا فاطمه امیر مهدی نرگس لیلا".split(),
    "روز هفته ماه سال ساعت دقیقه".split(),
]
KIND_OF = {w: i for i, ws in enumerate(KIND_WORDS) for w in ws if w != "نه"}  # «نه» is also "no"
FIXES = ["نه ببخشید", "نه یعنی", "یعنی نه", "نه نه", "ببخشید", "نه منظورم"]


def slip(hyp, rnd):
    w = hyp.split()
    spots = [i for i, x in enumerate(w) if x.strip("،.؟!") in KIND_OF]
    if not spots:
        return None
    i = rnd.choice(spots)
    kind = KIND_WORDS[KIND_OF[w[i].strip("،.؟!")]]
    wrong = rnd.choice([x for x in kind if x != w[i].strip("،.؟!") and x != "نه"])
    return " ".join(w[:i] + [wrong, rnd.choice(FIXES)] + w[i:])


rnd = random.Random(9)
n_slip = 0
for r in recs:
    if r["split"] != "train" or r["src"] == "para" or rnd.random() > 0.35:
        continue
    h = slip(r["hyp"], rnd)
    if h is None:
        continue
    for k in ("fix", rnd.choice(["formal", "casual", "summary"])):
        if ok(k, r[k], r["ref"]):
            train.append((k, h, r[k]))
            n_slip += 1
log(f"{n_slip} self-correction training examples")


# Cut-off words: the speaker starts a word, stops and says it whole («موبا موبایل», «می‌خوا می‌خواستم»);
# the speech model writes the fragment as a short nonsense word. Inserted before 1-2 words of
# Shenava's text; targets unchanged. Held-out speech rows get the same for the "cut" test set.
def cut(hyp, rnd):
    w = hyp.split()
    spots = [i for i, x in enumerate(w) if len(x.strip("،.؟!")) >= 4]
    if not spots:
        return None
    for i in sorted(rnd.sample(spots, min(len(spots), rnd.choice([1, 1, 2]))), reverse=True):
        x = w[i].strip("،.؟!")
        w.insert(i, x[:rnd.randint(2, len(x) - 2)])
    return " ".join(w)


n_cut = 0
for r in recs:
    if r["split"] != "train" or r["src"] == "para" or rnd.random() > 0.15:
        continue
    h = cut(r["hyp"], rnd)
    if h is not None and ok("fix", r["fix"], r["ref"]):
        train.append(("fix", h, r["fix"]))
        n_cut += 1
log(f"{n_cut} cut-off word training examples")
held["cut"] = [dict(r, hyp=h) for r in held["asr"] for h in [cut(r["hyp"], rnd)] if h is not None]
held["slip"] = []
for r in held["asr"]:
    h = slip(r["hyp"], rnd)
    if h is not None:
        held["slip"].append(dict(r, hyp=h, slip=0))
random.shuffle(train)
train = train[:MAX_TRAIN]
log(f"{len(recs)} teacher rows, {len(train)} training examples, kept {kept}, dropped {dropped}, held out { {k: len(v) for k, v in held.items()} }")

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
MARK = re.compile("نه ببخشید|یعنی نه|نه نه|ببخشید|منظورم")
random.Random(5).shuffle(held["asr"])
random.Random(5).shuffle(held["noisy"])
sets = {"asr": held["asr"][:EVAL_N], "noisy": held["noisy"][:EVAL_N], "disfl": held["disfl"][:EVAL_N], "cut": [r for r in held["cut"] if r["id"] not in {x["id"] for x in held["asr"][:EVAL_N]}][:EVAL_N], "slip": [r for r in held["slip"] if r["id"] not in {x["id"] for x in held["asr"][:EVAL_N]}][:EVAL_N],
        "para": held["para"][:120]}
chrf = CHRF(word_order=2)


def guard(inp, out):
    """Fix mode safety net: keep the input when the output strays too far from it."""
    a, b = words(inp), words(out)
    if not b or (re.search("[A-Za-z]", out) and not re.search("[A-Za-z]", inp)):
        return inp
    if not MARK.search(inp) and dist(a, b) > max(2, 0.3 * len(a)):
        return inp
    return out

lines = [f"base {BASE}, {done}/{steps} steps, {len(train)} examples, kept {kept}, dropped {dropped}"]
evalf = open(f"{OUT}/eval.jsonl", "w", encoding="utf-8")
for name, rows in sets.items():
    if not rows:
        continue
    results = {k: [] for k in STYLES}
    t = time.time()
    for k in STYLES:
        for i in range(0, len(rows), 16):
            chunk = rows[i:i + 16]
            enc = tok([prompt(k, r["hyp"]) for r in chunk], return_tensors="pt", padding=True, add_special_tokens=False).to("cuda")
            with torch.no_grad(), torch.autocast("cuda", dtype=torch.float16):
                gen = model.generate(**enc, max_new_tokens=400, do_sample=False, pad_token_id=tok.pad_token_id)
            for r, g in zip(chunk, gen[:, enc["input_ids"].shape[1]:]):
                results[k].append((r, tok.decode(g, skip_special_tokens=True).strip()))
    gen_s = (time.time() - t) / (len(rows) * len(STYLES))
    lines.append(f"\n##### set {name}: {len(rows)} held-out texts, {gen_s * 1000:.0f} ms per text (batched, T4)")
    for k, rs in results.items():
        for r, o in rs:
            evalf.write(json.dumps({"set": name, "style": k, "id": r["id"], "hyp": r["hyp"], "ref": r["ref"], "teacher": r[k],
                                    "student": o}, ensure_ascii=False) + "\n")
    ref_words = sum(len(words(r["ref"])) for r, _ in results["fix"])
    before = sum(dist(words(r["ref"]), words(r["hyp"])) for r, _ in results["fix"])
    after = sum(dist(words(r["ref"]), words(o)) for r, o in results["fix"])
    lines.append(f"[fix] word errors vs intended text (ZWNJ as space, marks ignored): input {100 * before / ref_words:.1f}% -> "
                 f"student {100 * after / ref_words:.1f}%")
    guarded = [guard(r["hyp"], o) for r, o in results["fix"]]
    g_after = sum(dist(words(r["ref"]), words(g)) for (r, _), g in zip(results["fix"], guarded))
    kept_in = sum(g == r["hyp"] for (r, _), g in zip(results["fix"], guarded))
    lines.append(f"[fix + guard] word errors {100 * g_after / ref_words:.1f}%, input kept unchanged {kept_in} of {len(guarded)}")
    if name == "disfl":
        fill = re.compile(r"(^|\s)(اه|ام|اِم|چیزه)(?=\s|$|[،.؟!])")
        left = sum(bool(fill.search(o)) for _, o in results["fix"])
        exact = sum(words(o) == words(r["ref"]) for r, o in results["fix"])
        lines.append(f"[disfluencies] fillers left in output {left} of {len(results['fix'])}, output = intended exactly {exact}")
    if name == "slip":
        sc = [(r, o) for r, o in results["fix"] if r.get("slip") in (0, 1, 3)]
        if sc:
            w = sum(len(words(r["ref"])) for r, _ in sc)
            b = sum(dist(words(r["ref"]), words(r["hyp"])) for r, _ in sc)
            a2 = sum(dist(words(r["ref"]), words(o)) for r, o in sc)
            left = sum(bool(MARK.search(o)) for _, o in sc)
            exact = sum(words(o) == words(r["ref"]) for r, o in sc)
            lines.append(f"[self-correction] {len(sc)} texts: word errors {100 * b / w:.1f}% -> {100 * a2 / w:.1f}%, "
                         f"correction words left in output {left}, output = intended exactly {exact}")
    for k, rs in results.items():
        score = chrf.corpus_score([o for _, o in rs], [[r[k] for r, _ in rs]]).score
        base_score = chrf.corpus_score([r["hyp"] for r, _ in rs], [[r[k] for r, _ in rs]]).score
        numbers = sum(nums(o) <= nums(r["ref"]) for r, o in rs) / len(rs)
        ratio = sum(len(o) for _, o in rs) / max(1, sum(len(r["ref"]) for r, _ in rs))
        tratio = sum(len(r[k]) for r, _ in rs) / max(1, sum(len(r["ref"]) for r, _ in rs))
        spoken = sum(any(m in f" {o} " for m in COLLOQUIAL) for _, o in rs) / len(rs)
        lines.append(f"[{k}] chrF++ vs teacher {score:.1f} (input as is {base_score:.1f}), no new numbers {100 * numbers:.0f}%, "
                     f"length / intended: student {ratio:.2f} teacher {tratio:.2f}, spoken forms in output {100 * spoken:.0f}%")
    lines.append("--- samples")
    for k, rs in results.items():
        lines.append(f"\n=== {name} [{STYLES[k]}]")
        for r, o in rs[:4]:
            lines += [f"ورودی: {r['hyp']}", f"شاگرد: {o}", f"معلم: {r[k]}", f"منظور: {r['ref']}", ""]
evalf.close()
lines.append(f"hours {(time.time() - T0) / 3600:.1f}")
open(f"{OUT}/summary.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
