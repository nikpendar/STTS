# Stage 2b of the dictation-correction student (round 2): longer and spoken-style data, which round 1
# lacked (its inputs were single read-aloud sentences, so formal and summary learned little).
#  mono: the teacher (Qwen3-30B-A3B-Instruct-2507) invents everyday dictated messages (voice message to a
#        friend, note to self, email to a manager, request to support, ...), 1-5 sentences, as the
#        intended text and as it was spoken: colloquial, with self-corrections («نه ببخشید ...»),
#        repeats, fillers and restarts. A tenth is held out: the self-correction test set.
#  para: Persian Wikipedia paragraphs of 3-5 sentences (CC BY-SA), spoken-style input with one slip;
#        mostly for summaries of longer text. 5% held out.
# First run (2026-11-07): mono rejected (odd invented content, corrections left in the intended text) and
# paragraphs failed (answers cut at 1024 tokens per slot); now paragraphs only, 3072 tokens per slot.
# Then the teacher writes fix / formal / casual / summary of the intended text (summary of a text of
# 3+ sentences at most about half as long). Student input = the spoken text as Shenava writes it
# (ZWNJ as a space, marks often missing). Output /kaggle/working/teach2.jsonl.
import glob, json, os, random, re, shutil, subprocess, sys, threading, time, unicodedata, urllib.request
from concurrent.futures import ThreadPoolExecutor

T0 = time.time()
BUDGET_H = float(os.environ.get("BUDGET_H", "10.5"))
MONO = int(os.environ.get("MONO", "0"))  # 6000 in the first run: invented messages were too odd to use
PARA = int(os.environ.get("PARA", "1500"))
SLOTS = 16  # 32 slots x 1024 tokens cut paragraph answers short in the first run
CTX = 3072
OUT = "/kaggle/working"
TMP = "/kaggle/temp"
REPO = "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF"
FILE = "Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
ZWNJ = "‌"
random.seed(11)


def log(*a):
    print(f"[{(time.time() - T0) / 3600:5.2f} h]", *a, flush=True)


def shenava(text):
    """The spoken text as the speech model writes it."""
    text = unicodedata.normalize("NFKC", text).replace("ي", "ی").replace("ك", "ک")
    text = re.sub("[ً-ْٰٔـ]", "", text).replace(ZWNJ, " ")
    text = re.sub(r"[«»()\[\]\-\"…]", " ", text)
    if random.random() < 0.6:
        text = re.sub("[،؛:.!؟]", " ", text)
    return " ".join(text.split())


# --- Wikipedia paragraphs
from huggingface_hub import hf_hub_download, list_repo_files
import pandas as pd

good = re.compile("^[؀-ۿ‌\\s،؛:.!؟«»()\\-]+$")
digits = re.compile("[0-9۰-۹٠-٩]")
paras = []
files = sorted(f for f in list_repo_files("wikimedia/wikipedia", repo_type="dataset") if f.startswith("20231101.fa/"))
for f in files[1:]:  # round 1 sampled sentences from the first file
    df = pd.read_parquet(hf_hub_download("wikimedia/wikipedia", f, repo_type="dataset"), columns=["text"])
    for doc in df["text"].sample(frac=1, random_state=2):
        for p in doc.split("\n"):
            p = p.strip()
            n, s = len(p.split()), len(re.findall(r"[.؟!](\s|$)", p))
            if 40 <= n <= 120 and 3 <= s <= 6 and good.match(p) and not digits.search(p) and "()" not in p:
                paras.append(p)
                break  # one paragraph per article
        if len(paras) >= PARA:
            break
    if len(paras) >= PARA:
        break
log(f"{len(paras)} paragraphs")

KINDS = ["پیام صوتی به یک دوست", "یادداشت برای خودم", "ایمیل به مدیرم", "پیام به همکار", "پیام به گروه خانوادگی",
         "درخواست از پشتیبانی یک شرکت", "پیام به صاحبخانه", "پیام به معلم یا استاد", "توضیح یک مشکل برای تعمیرکار",
         "سفارش غذا یا خرید", "تعریف کردن اتفاق امروز برای یک دوست", "یادآوری قرار ملاقات", "شکایت از یک خدمات",
         "تبریک یا تشکر", "برنامه‌ریزی سفر با دوستان", "گزارش کار روزانه برای تیم", "پیام به پزشک یا مطب"]
TOPICS = ["کار", "دانشگاه", "خرید", "سفر", "سلامتی", "خانه", "ماشین", "بانک", "ورزش", "آشپزی", "مهمانی", "فیلم و کتاب",
          "بچه‌ها و مدرسه", "تعمیرات", "اینترنت و گوشی", "هوا", "اجاره خانه", "جلسه کاری", "پروژه نرم‌افزاری", "تولد",
          "قبض و پرداخت", "مسافرت کاری", "باشگاه", "حیوان خانگی", "همسایه‌ها", "رستوران", "کلاس زبان", "اسباب‌کشی"]
SLIPS = ["یک بار وسط حرف خودش را اصلاح کند (مثلاً «… نه ببخشید …» یا «… یعنی نه …») و جای چیزی مثل ساعت، روز، عدد، نام یا مکان را عوض کند",
         "دو بار خودش را اصلاح کند (مثلاً «نه نه» یا «ببخشید منظورم … بود»)",
         "یک کلمه را تکرار کند و یک بار جمله را نیمه‌کاره رها کند و از نو بگوید",
         "با «خب» یا «ببین» شروع کند و یک بار خودش را اصلاح کند",
         "بدون هیچ اشتباهی حرف بزند"]
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
server = subprocess.Popen(f"{BIN}/llama-server -m {model} -ngl 99 -c {SLOTS * CTX} -np {SLOTS} --split-mode layer "
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

GEN = (
    "تو برای آموزش یک مدل اصلاح دیکته‌ی فارسی داده می‌سازی. یک پیام کوتاه بساز که کسی آن را با صدا دیکته کرده است، "
    "و فقط یک شیء JSON با دو کلید برگردان:\n"
    "- spoken: دقیقاً همان چیزی که گوینده به زبان آورده: فارسی گفتاری تهرانی (میام، می‌خوام، رو، میشه)، عددها با حروف، "
    "با همه‌ی لغزش‌هایی که خواسته شده.\n"
    "- intended: متنی که گوینده واقعاً منظورش بوده: اصلاح‌های وسط حرف اعمال شده (فقط شکل نهایی)، تکرار و «خب/ببین/اوم» و جمله‌ی "
    "نیمه‌کاره حذف شده، ولی بقیه‌ی کلمه‌ها و لحن عیناً همان spoken؛ با املای استاندارد، نیم‌فاصله و نشانه‌گذاری درست؛ عددها با حروف.\n"
    "نام‌ها و جاها معمولی و ایرانی باشند. موضوع واقعی و روزمره باشد. توضیح اضافه ننویس."
)
STYLE = (
    "تو ویراستار زبان فارسی هستی. به تو یک «متن» داده می‌شود: متنی که گوینده منظورش بوده است. چهار نسخه از آن بنویس "
    "و فقط یک شیء JSON با کلیدهای fix، formal، casual و summary برگردان.\n"
    "- fix: دقیقاً همان کلمه‌ها و همان لحن؛ فقط املای استاندارد، نیم‌فاصله و نشانه‌گذاری درست. محاوره‌ای، محاوره‌ای بماند.\n"
    "- formal: همان معنی به فارسی نوشتاری رسمی و مؤدبانه؛ هیچ شکل گفتاری (میام، می‌خوام، رو، یه، میشه) نماند.\n"
    "- casual: همان معنی به فارسی محاوره‌ای و خودمانی، مثل پیام به دوست (می‌خوام، میام، رو، یه)، با نیم‌فاصله‌ی درست.\n"
    "- summary: خلاصه به فارسی نوشتاری با همه‌ی اطلاعات اصلی (زمان، عدد، نام، درخواست). اگر متن سه جمله یا بیشتر است، "
    "حداکثر نصف طول متن باشد؛ اگر کوتاه است، فقط مرتب و کمی کوتاه‌تر.\n"
    "قاعده‌ها: هیچ نام، عدد، مکان، زمان یا اطلاعاتی اضافه نکن و چیزی را عوض نکن؛ شخص فعل‌ها را تغییر نده؛ توضیح نده."
)


def schema(keys):
    return {"type": "object", "properties": {k: {"type": "string"} for k in keys}, "required": list(keys)}


def chat(system, user, keys, temperature):
    body = {"messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "temperature": temperature, "top_p": 0.95, "max_tokens": 1200,
            "response_format": {"type": "json_schema", "json_schema": {"name": "out", "schema": schema(keys)}}}
    req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=900))
    v = json.loads(r["choices"][0]["message"]["content"])
    return {k: v[k].strip() for k in keys}, r["usage"]["completion_tokens"]


STYLES = ("fix", "formal", "casual", "summary")
items = [("mono", i) for i in range(MONO)] + [("para", i) for i in range(len(paras))]
random.shuffle(items)
lock = threading.Lock()
out = open(f"{OUT}/teach2.jsonl", "w", encoding="utf-8")
stats = {"n": 0, "tokens": 0, "failed": 0, "rejected": 0}
deadline = T0 + BUDGET_H * 3600
MARK = re.compile("نه ببخشید|یعنی نه|نه نه|ببخشید|منظورم|نه،")


def work(item):
    src, i = item
    if time.time() > deadline:
        return
    rnd = random.Random(i * 7 + (src == "para"))
    tokens = 0
    try:
        if src == "mono":
            slip = rnd.randrange(len(SLIPS))
            user = (f"نوع: {rnd.choice(KINDS)}\nموضوع: {rnd.choice(TOPICS)}\nطول: {rnd.choice([1, 2, 2, 3, 3, 4, 5])} جمله\n"
                    f"گوینده باید {SLIPS[slip]}.")
            g, n = chat(GEN, user, ("spoken", "intended"), 0.9)
            tokens += n
            spoken, ref = g["spoken"], g["intended"]
            needs_mark = slip in (0, 1, 3)
            if (not spoken or not ref or digits.search(spoken) or len(ref) > len(spoken) + 10
                    or (needs_mark and not MARK.search(spoken)) or "نه ببخشید" in ref):
                with lock:
                    stats["rejected"] += 1
                return
            split = "heldout" if i % 10 == 0 else "train"
        else:
            slip, ref = -1, paras[i]
            w = ref.split()
            k = rnd.randrange(1, len(w))
            spoken = " ".join(w[:k] + [w[k]] + w[k:]) if rnd.random() < 0.5 else "خب " + ref
            split = "heldout" if i % 20 == 0 else "train"
        v, n = chat(STYLE, "متن: " + ref, STYLES, 0.2)
        tokens += n
    except Exception as e:  # noqa: BLE001
        with lock:
            stats["failed"] += 1
            if stats["failed"] <= 5:
                log("failed", src, i, repr(e)[:300])
        return
    rec = {"id": f"{src}-{i}", "src": src, "split": split, "slip": slip, "spoken": spoken, "hyp": shenava(spoken), "ref": ref} | v
    with lock:
        out.write(json.dumps(rec, ensure_ascii=False) + "\n")
        stats["n"] += 1
        stats["tokens"] += tokens
        if stats["n"] % 500 == 0:
            out.flush()
            log(f"{stats}, {stats['tokens'] / (time.time() - T0):.0f} tokens/s overall")


t = time.time()
with ThreadPoolExecutor(SLOTS * 2) as ex:
    list(ex.map(work, items))
out.close()
server.terminate()
recs = [json.loads(l) for l in open(f"{OUT}/teach2.jsonl", encoding="utf-8")]
lines = [f"{stats} of {len(items)} items in {(time.time() - t) / 3600:.2f} h",
         f"mono {sum(r['src'] == 'mono' for r in recs)} (held out {sum(r['src'] == 'mono' and r['split'] == 'heldout' for r in recs)}), "
         f"para {sum(r['src'] == 'para' for r in recs)}", "--- samples"]
for r in random.sample(recs, min(10, len(recs))):
    lines += [f"\n{r['src']} slip {r['slip']}", f"گفته: {r['spoken']}", f"ورودی: {r['hyp']}", f"منظور: {r['ref']}"] + \
             [f"[{k}] {r[k]}" for k in STYLES]
open(f"{OUT}/summary.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
