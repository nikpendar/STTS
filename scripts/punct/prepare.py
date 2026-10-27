"""Builds training and test sets for Persian punctuation restoration.

Sources (all fetched from Hugging Face's parquet API, not gated):
  - Persian Wikipedia (wikimedia/wikipedia 20231101.fa): prose paragraphs cut into 1..4 sentence chunks;
    articles under 1500 characters (bot village stubs) are skipped, as in make_bigrams.py.
  - Questions (SajjadAyoubi/persian_qa): question sentences, since Wikipedia has almost none.
  - FLEURS fa_ir test transcripts (raw, punctuated): an unseen test set close to dictated speech.
Writes jsonl lines {"words": [...], "labels": [...]} to OUT/{train,dev,test_wiki,test_fleurs}.jsonl.
"""
import io, json, random, re, sys, urllib.request
import pyarrow.parquet as pq
from common import label_text, PERSIAN

OUT = sys.argv[1]
TRAIN_TARGET = int(sys.argv[2]) if len(sys.argv) > 2 else 400_000
random.seed(7)


def get(url):
    with urllib.request.urlopen(url, timeout=600) as r:
        return r.read()


def parquet_urls(dataset, config, split):
    return json.loads(get(f"https://huggingface.co/api/datasets/{dataset}/parquet/{config}/{split}"))


SENT_END = re.compile(r"(?<=[.؟?!])\s+")


def prose(par):
    if len(par) < 80 or par[-1] not in ".؟?!":
        return False
    letters = sum(c.isalpha() for c in par)
    return letters and len(PERSIAN.findall(par)) / letters > 0.9 and sum(c.isdigit() for c in par) < 0.1 * len(par)


def chunks(par):
    sents = [s for s in SENT_END.split(par) if s]
    i = 0
    while i < len(sents):
        k = random.choice((1, 1, 2, 2, 3, 4))
        words, labels = label_text(" ".join(sents[i:i + k]))
        i += k
        if 4 <= len(words) <= 70 and labels[-1] in (2, 3):
            yield words, labels


def write(name, rows):
    with open(f"{OUT}/{name}.jsonl", "w", encoding="utf-8") as f:
        for words, labels in rows:
            f.write(json.dumps({"words": words, "labels": labels}, ensure_ascii=False) + "\n")
    print(name, len(rows))


wiki = []
for url in parquet_urls("wikimedia/wikipedia", "20231101.fa", "train")[:2]:
    table = pq.read_table(io.BytesIO(get(url)), columns=["text"])
    for text in table.column("text").to_pylist():
        if len(text) < 1500:
            continue
        for par in text.split("\n"):
            par = par.strip()
            if prose(par):
                wiki.extend(chunks(par))
    print("wiki chunks so far", len(wiki))
    if len(wiki) > TRAIN_TARGET + 6000:
        break
random.shuffle(wiki)

questions = []
for split in ("train", "validation"):
    try:
        for url in parquet_urls("SajjadAyoubi/persian_qa", "default", split):
            table = pq.read_table(io.BytesIO(get(url)), columns=["question"])
            for q in set(table.column("question").to_pylist()):
                q = q.strip()
                if q and q[-1] not in "؟?.":
                    q += "؟"
                words, labels = label_text(q)
                if 3 <= len(words) <= 40 and labels[-1] == 3:
                    questions.append((words, labels))
    except Exception as e:  # questions are a bonus; Wikipedia alone still trains comma and period
        print("questions unavailable:", e)
random.shuffle(questions)
print("questions", len(questions))

# Mix: some questions stand alone, some follow a Wikipedia sentence, as in dictated messages.
test_q, train_q = questions[:1000], questions[1000:]
test_wiki = wiki[:3000] + test_q
train = wiki[6000:6000 + TRAIN_TARGET]
for i, q in enumerate(train_q):
    if i % 2 and train:
        w, l = random.choice(wiki[6000:])
        train.append((w + q[0], l + q[1]))
    else:
        train.append(q)
random.shuffle(train)
random.shuffle(test_wiki)
write("train", train)
write("dev", wiki[3000:4000])
write("test_wiki", test_wiki)

tsv = get("https://huggingface.co/datasets/google/fleurs/resolve/main/data/fa_ir/test.tsv").decode("utf-8")
seen, fleurs = set(), []
for line in tsv.splitlines():
    cols = line.split("\t")
    if len(cols) > 2 and cols[2] not in seen:
        seen.add(cols[2])
        words, labels = label_text(cols[2])
        if len(words) >= 3:
            fleurs.append((words, labels))
write("test_fleurs", fleurs)
