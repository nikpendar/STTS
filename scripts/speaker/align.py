# Matches transcribed pieces to the script's sentences (in order, with retakes and skips).
# usage: align.py SENTENCES CHUNKS_JSON FIRST LAST  -> prints JSON list of {id, t0, t1, sim, text}
import sys, json, re
from difflib import SequenceMatcher
sents = {}
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"\s*(\d+)\.\s*(.*)", line)
    if m: sents[int(m.group(1))] = m.group(2).strip()
chunks = json.load(open(sys.argv[2]))
first, last = int(sys.argv[3]), int(sys.argv[4])
ids = list(range(first, last + 1))

def norm(t):
    t = t.replace("ي", "ی").replace("ك", "ک").replace("‌", "")
    return re.sub(r"[^؀-ۿ0-9A-Za-z]", "", t)

def sim(a, b):
    a, b = norm(a), norm(b)
    # whisper sometimes repeats a phrase on short pieces: compare only the start
    a = a[:int(len(b) * 1.3) + 2]
    return SequenceMatcher(None, a, b, autojunk=False).ratio() if a and b else 0.0

N, M = len(chunks), len(ids)
NEG = -1e9
# f[i][j]: best score with chunks[:i] used, last sentence index j (-1 => j=0 slot means none)
f = [[NEG] * (M + 1) for _ in range(N + 1)]
back = [[None] * (M + 1) for _ in range(N + 1)]
f[0][0] = 0
for i in range(N):
    for j in range(M + 1):
        if f[i][j] == NEG: continue
        # junk piece
        if f[i][j] > f[i + 1][j]:
            f[i + 1][j], back[i + 1][j] = f[i][j], (i, j, None)
        for L in range(1, 5):
            if i + L > N: break
            text = " ".join(c["text"] for c in chunks[i:i + L])
            for j2 in range(max(1, j), min(M, j + 4) + 1):  # same sentence again (retake) or next ones
                s = sim(text, sents[ids[j2 - 1]])
                if s < 0.5: continue
                v = f[i][j] + s - 0.25 - 0.05 * (L - 1)
                if v > f[i + L][j2]:
                    f[i + L][j2], back[i + L][j2] = v, (i, j, (j2, s))
            # two sentences read without a pause
            for j2 in (range(max(1, j), min(M - 1, j + 4) + 1) if L == 1 else ()):
                s = sim(text, sents[ids[j2 - 1]] + " " + sents[ids[j2]])
                if s < 0.85 or s < max(sim(text, sents[ids[j2 - 1]]), sim(text, sents[ids[j2]])) + 0.1: continue
                v = f[i][j] + 2 * (s - 0.25)
                if v > f[i + L][j2 + 1]:
                    f[i + L][j2 + 1], back[i + L][j2 + 1] = v, (i, j, (j2, s, 2))
j = max(range(M + 1), key=lambda k: f[N][k])
path, i = [], N
while i > 0:
    pi, pj, a = back[i][j]
    if a and len(a) == 3:
        path.append((pi, i, a[0] + 1, a[1], "second"))
        path.append((pi, i, a[0], a[1], "first"))
    elif a: path.append((pi, i, a[0], a[1], ""))
    i, j = pi, pj
path.reverse()
out = [{"id": ids[j2 - 1], "t0": chunks[a]["t0"], "t1": chunks[b - 1]["t1"], "sim": round(s, 3), "part": part,
        "heard": " ".join(c["text"] for c in chunks[a:b]), "text": sents[ids[j2 - 1]]} for a, b, j2, s, part in path]
json.dump(out, sys.stdout, ensure_ascii=False, indent=0)
