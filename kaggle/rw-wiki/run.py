# Stage 1b of the dictation-correction student: synthetic dictation from Persian Wikipedia
# (CC BY-SA). Each written sentence (the target, punctuation and ZWNJ intact) gets a spoken-style
# input as the speech model writes it (no ZWNJ, no punctuation, numbers in words), with one of:
# self-correction («… نه ببخشید …», «یعنی نه»), a repeated word, a filler at the start, or nothing.
# Output /kaggle/working/wiki.jsonl: {id, kind, ref, hyp}; summary.txt with counts and samples. CPU.
import json, os, random, re, subprocess, time, unicodedata

subprocess.run("pip install -q num2fawords", shell=True, check=True)
from huggingface_hub import hf_hub_download, list_repo_files
from num2fawords import words as fa_words
import pandas as pd

T0 = time.time()
OUT = "/kaggle/working"
N = int(os.environ.get("N", "40000"))
random.seed(7)

files = sorted(f for f in list_repo_files("wikimedia/wikipedia", repo_type="dataset") if f.startswith("20231101.fa/"))
print(len(files), "parquet files", flush=True)


def spoken(text):
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("ي", "ی").replace("ك", "ک")
    text = re.sub(r"[۰-۹]", lambda m: str("۰۱۲۳۴۵۶۷۸۹".index(m.group())), text)
    text = re.sub(r"\d+", lambda m: fa_words(int(m.group())) if len(m.group()) < 10 else m.group(), text)
    text = re.sub("[ً-ٰٟـ]", "", text).replace("‌", "")
    text = re.sub(r"[^\w\s]|_", " ", text)
    return " ".join(text.split())


good = re.compile(r"^[؀-ۿ‌\s\d۰-۹،؛:.!؟«»()\-]+$")
sentences = []
for f in files:
    df = pd.read_parquet(hf_hub_download("wikimedia/wikipedia", f, repo_type="dataset"), columns=["text"])
    for doc in df["text"].sample(frac=1, random_state=1):
        for para in doc.split("\n"):
            for s in re.split(r"(?<=[.؟!])\s+", para.strip()):
                n = len(s.split())
                if 6 <= n <= 30 and s.endswith((".", "؟", "!")) and good.match(s) and "()" not in s:
                    sentences.append(s)
        if len(sentences) > N * 3:
            break
    if len(sentences) > N * 3:
        break
random.shuffle(sentences)
sentences = sentences[:N]
vocab = [w for s in sentences[:5000] for w in spoken(s).split() if len(w) > 2]
CORRECT = ["نه ببخشید", "نه یعنی", "یعنی نه", "نه نه", "ببخشید"]
FILL = ["خب", "ببین", "خب ببین", "اوم", "یعنی"]

with open(f"{OUT}/wiki.jsonl", "w", encoding="utf-8") as out:
    counts = {}
    for i, ref in enumerate(sentences):
        words = spoken(ref).split()
        r = random.random()
        k = random.randrange(1, len(words))
        if r < 0.35:  # said a wrong word first, then corrected it
            kind = "correction"
            words = words[:k] + [random.choice(vocab), random.choice(CORRECT)] + words[k:]
        elif r < 0.5:
            kind = "repeat"
            words = words[:k] + [words[k]] + words[k:]
        elif r < 0.6:
            kind = "filler"
            words = [random.choice(FILL)] + words
        else:
            kind = "plain"
        counts[kind] = counts.get(kind, 0) + 1
        out.write(json.dumps({"id": f"wiki-{i}", "kind": kind, "ref": ref, "hyp": " ".join(words)}, ensure_ascii=False) + "\n")

lines = [f"{len(sentences)} sentences {counts}", "--- samples (ref | hyp)"]
rows = [json.loads(l) for l in open(f"{OUT}/wiki.jsonl", encoding="utf-8")]
lines += [f"{r['kind']}: {r['ref']} | {r['hyp']}" for r in rows[:12]]
lines.append(f"minutes {(time.time() - T0) / 60:.0f}")
open(f"{OUT}/summary.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
