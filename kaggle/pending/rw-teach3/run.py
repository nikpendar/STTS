# Stage 2c of the dictation-correction student (round 3). The teacher (Qwen3-30B-A3B-Instruct-2507)
# writes fix / formal / casual / summary again for every round-1 sentence, with the round-2 rules that
# worked on paragraphs (formal and summary in written Persian with no spoken forms, meaning and sentence
# structure kept, nothing added or changed), and for the new real speech-model errors of kaggle/rw-asr2
# (CV train/other, partly degraded like phone audio). Each distinct correct sentence is asked once and
# shared by all its recordings (CV sentences repeat). Held out: round-1 rows (src asr) and the degraded
# held-out copies of rw-asr2 (src noisy). Output /kaggle/working/teach3.jsonl in the format of teach.jsonl.
import glob, json, os, random, shutil, subprocess, sys, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

T0 = time.time()
BUDGET_H = float(os.environ.get("BUDGET_H", "11.0"))
OUT = "/kaggle/working"
TMP = "/kaggle/temp"
SLOTS = int(os.environ.get("SLOTS", "32"))
CLEAN = int(os.environ.get("CLEAN", "3000"))
WIKI = int(os.environ.get("WIKI", "6000"))
REPO = "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF"
FILE = "Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
random.seed(3)


def log(*a):
    print(f"[{(time.time() - T0) / 3600:5.2f} h]", *a, flush=True)


def find(name):
    hits = glob.glob(f"/kaggle/input/**/{name}", recursive=True)
    if not hits:
        sys.exit(f"{name} not found under /kaggle/input")
    return hits[0]


def rows(path):
    return [json.loads(l) for l in open(path, encoding="utf-8")]


asr, asr2, wiki = rows(find("asr.jsonl")), rows(find("asr2.jsonl")), rows(find("wiki.jsonl"))
held = [dict(r, src="asr") for r in asr if r["split"] == "heldout"]
held += [dict(r, src="noisy") for r in asr2 if r["split"] == "heldout"]
train = [dict(r, src="asr") for r in asr + asr2 if r["split"] == "train"]
random.shuffle(train)
errs = [r for r in train if r["wer"] > 0]
clean = [r for r in train if r["wer"] == 0][:CLEAN]
rec_items = held + errs + clean + [dict(r, src="wiki", split="train") for r in wiki[:WIKI]]
by_ref = {}
for r in rec_items:  # one teacher call per distinct sentence, in this order of priority
    by_ref.setdefault(r["ref"].strip(), []).append(r)
items = list(by_ref)
log(f"{len(held)} held out, {len(errs)} with errors, {len(clean)} clean, {min(WIKI, len(wiki))} wiki; "
    f"{len(items)} distinct sentences for {len(rec_items)} rows")

BIN = f"{TMP}/llama-bin"
built = glob.glob("/kaggle/input/**/llama-bin/llama-server", recursive=True)
if built:
    shutil.copytree(os.path.dirname(built[0]), BIN)
else:  # kaggle/rw-llama output missing: build here (about 30 min)
    log("building llama-server")
    real = subprocess.run("find / -path /proc -prune -o -name 'libcuda.so.1' -print 2>/dev/null | head -1",
                          shell=True, capture_output=True, text=True).stdout.strip()
    os.makedirs(f"{TMP}/cudalib", exist_ok=True)
    os.symlink(real, f"{TMP}/cudalib/libcuda.so")
    subprocess.run(f"git clone -q --depth 1 https://github.com/ggml-org/llama.cpp {TMP}/llama.cpp && cd {TMP}/llama.cpp && "
                   f"cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=75 -DLLAMA_CURL=OFF "
                   f"-DCUDA_cuda_driver_LIBRARY={TMP}/cudalib/libcuda.so -DCMAKE_BUILD_TYPE=Release > /dev/null && "
                   f"cmake --build build -j{os.cpu_count()} --target llama-server 2>&1 | grep -iE ' error' | head",
                   shell=True, check=True)
    shutil.copytree(f"{TMP}/llama.cpp/build/bin", BIN)
subprocess.run(f"chmod +x {BIN}/*", shell=True, check=True)
from huggingface_hub import hf_hub_download

model = hf_hub_download(REPO, FILE, local_dir=f"{TMP}/model")
log("model ready")
env = dict(os.environ, LD_LIBRARY_PATH=BIN + ":" + os.environ.get("LD_LIBRARY_PATH", ""))
server = subprocess.Popen(f"{BIN}/llama-server -m {model} -ngl 99 -c {SLOTS * 1536} -np {SLOTS} --split-mode layer "
                          f"--jinja --port 8080 --log-disable", shell=True, env=env)
for _ in range(600):
    try:
        if json.load(urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=2)).get("status") == "ok":
            break
    except Exception:  # noqa: BLE001
        pass
    if server.poll() is not None:
        sys.exit("server exited")
    time.sleep(2)
log("server up")

SYSTEM = (
    "تو ویراستار زبان فارسی هستی. به تو یک «متن» داده می‌شود: جمله‌ای که گوینده واقعاً گفته است. چهار نسخه از آن بنویس "
    "و فقط یک شیء JSON با کلیدهای fix، formal، casual و summary برگردان.\n"
    "- fix: دقیقاً همان کلمه‌ها و همان لحن؛ فقط املای استاندارد، نیم‌فاصله (مثل می‌شود، خانه‌ها، کتاب‌هایش، رفته‌اند) و نشانه‌گذاری درست. "
    "اگر متن محاوره‌ای است، محاوره‌ای بماند. عددها را همان‌طور که در متن آمده بنویس.\n"
    "- formal: همان جمله به فارسی نوشتاری رسمی و مؤدبانه؛ ساختار و معنی جمله را تا جای ممکن نگه دار و فقط شکل‌های گفتاری و "
    "غیررسمی را نوشتاری کن؛ هیچ شکل گفتاری (میام، می‌خوام، رو، یه، میشه) نماند. اگر متن از قبل رسمی است، تقریباً همان fix بماند.\n"
    "- casual: همان معنی به فارسی محاوره‌ای و خودمانی، مثل پیام به دوست (می‌خوام، میام، رو، یه)، با نیم‌فاصله‌ی درست.\n"
    "- summary: کوتاه‌ترین شکل روان به فارسی نوشتاری (نه محاوره‌ای) که همه‌ی اطلاعات اصلی را نگه دارد. "
    "اگر متن کوتاه است، تقریباً همان fix بماند.\n"
    "قاعده‌ها: معنی را عوض نکن؛ هیچ نام، عدد، مکان، زمان یا اطلاعاتی اضافه نکن و چیزی را عوض نکن؛ شخص و زمان فعل‌ها را تغییر نده؛ "
    "نام‌ها را کامل نکن و توضیح نده."
)
SCHEMA = {"type": "object", "properties": {k: {"type": "string"} for k in ("fix", "formal", "casual", "summary")},
          "required": ["fix", "formal", "casual", "summary"]}


def ask(item):
    body = {"messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": "متن: " + item}],
            "temperature": 0.2, "top_p": 0.9, "max_tokens": 700,
            "response_format": {"type": "json_schema", "json_schema": {"name": "versions", "schema": SCHEMA}}}
    req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=900))
    return json.loads(r["choices"][0]["message"]["content"]), r["usage"]["completion_tokens"]


lock = threading.Lock()
out = open(f"{OUT}/teach3.jsonl", "w", encoding="utf-8")
done = {"n": 0, "rows": 0, "tokens": 0, "failed": 0}
deadline = T0 + BUDGET_H * 3600


def work(item):
    if time.time() > deadline:
        return
    try:
        v, n = ask(item)
        v = {k: v[k].strip() for k in SCHEMA["required"]}
    except Exception as e:  # noqa: BLE001
        with lock:
            done["failed"] += 1
            if done["failed"] <= 5:
                log("failed", item[:60], repr(e)[:300])
        return
    with lock:
        for r in by_ref[item]:
            out.write(json.dumps({k: r.get(k) for k in ("id", "src", "split", "hyp", "ref")} | v, ensure_ascii=False) + "\n")
            done["rows"] += 1
        done["n"] += 1
        done["tokens"] += n
        if done["n"] % 500 == 0:
            out.flush()
            dt = time.time() - T0
            log(f"{done['n']}/{len(items)} sentences, {done['rows']} rows, {done['tokens'] / max(dt, 1):.0f} tokens/s overall")


t = time.time()
with ThreadPoolExecutor(SLOTS * 2) as ex:
    list(ex.map(work, items))
out.close()
server.terminate()
dt = time.time() - t
lines = [f"{done['n']} of {len(items)} sentences ({done.get('rows', 0)} rows) in {dt / 3600:.2f} h, {done['failed']} failed, "
         f"{done['tokens'] / dt:.0f} output tokens/s",
         f"held out {len(held)}, errors {len(errs)}, clean {len(clean)}, wiki {min(WIKI, len(wiki))}", "--- samples"]
recs = rows(f"{OUT}/teach3.jsonl")
for r in random.sample(recs, min(12, len(recs))):
    lines += [f"\n{r['src']} hyp: {r['hyp']}", f"ref: {r['ref']}"] + [f"[{k}] {r[k]}" for k in SCHEMA["required"]]
open(f"{OUT}/summary.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
