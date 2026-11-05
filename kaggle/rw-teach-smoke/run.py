# Teacher check for the dictation-correction student: Qwen3-30B-A3B-Instruct-2507 (Apache-2.0) as a
# 4-bit GGUF on Kaggle's two T4s with llama.cpp (built here for sm_75), served with parallel slots.
# Writes summary.txt: build/load times, throughput with 64 requests in flight, and every test
# sentence in the four styles. Nothing here is used as training data yet.
import json, os, subprocess, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

T0 = time.time()
OUT = "/kaggle/working"
TMP = "/kaggle/temp"
os.makedirs(TMP, exist_ok=True)
REPO = "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF"
FILE = "Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
SLOTS = 16
summary = []


def log(*a):
    msg = " ".join(str(x) for x in a)
    print(f"[{(time.time() - T0) / 60:5.1f} min] {msg}", flush=True)
    return msg


def sh(cmd):
    log("$", cmd)
    subprocess.run(cmd, shell=True, check=True)


sh("nvidia-smi --query-gpu=name,memory.total --format=csv; nvcc --version | tail -1; nproc; free -g | head -2")
t = time.time()
sh(f"git clone -q --depth 1 https://github.com/ggml-org/llama.cpp {TMP}/llama.cpp")
sh(f"cd {TMP}/llama.cpp && cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=75 -DLLAMA_CURL=OFF "
   f"-DCMAKE_BUILD_TYPE=Release > /dev/null && cmake --build build -j{os.cpu_count()} --target llama-server 2>&1 | tail -2")
summary.append(log(f"llama.cpp build {time.time() - t:.0f} s"))

from huggingface_hub import hf_hub_download

t = time.time()
model = hf_hub_download(REPO, FILE, local_dir=f"{TMP}/model")
summary.append(log(f"download {time.time() - t:.0f} s, {os.path.getsize(model) / 1e9:.1f} GB"))

t = time.time()
server = subprocess.Popen(f"{TMP}/llama.cpp/build/bin/llama-server -m {model} -ngl 99 -c {SLOTS * 2048} -np {SLOTS} "
                          f"--split-mode layer --jinja --port 8080 --log-disable", shell=True)
for _ in range(600):
    try:
        if json.load(urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=2)).get("status") == "ok":
            break
    except Exception:  # noqa: BLE001
        pass
    if server.poll() is not None:
        sys.exit("server exited")
    time.sleep(2)
summary.append(log(f"server load {time.time() - t:.0f} s"))
subprocess.run("nvidia-smi --query-gpu=memory.used --format=csv", shell=True)

COMMON = ("متن زیر خروجی خام تبدیل گفتار به متن فارسی است: نیم‌فاصله و نشانه‌گذاری ندارد و ممکن است کلمه‌ای اشتباه شنیده شده باشد "
          "یا گوینده وسط حرفش خودش را اصلاح کرده باشد (مثلاً «نه ببخشید»، «یعنی نه»). اگر گوینده حرفش را اصلاح کرده، فقط شکل نهایی را نگه دار. "
          "معنی و اطلاعات را عوض نکن و چیزی از خودت اضافه نکن. فقط متن نهایی را بنویس، بدون توضیح و بدون علامت نقل قول.")
STYLES = {
    "فقط اصلاح": "کمترین تغییر ممکن را بده: غلط‌های شنیداری و املایی، نیم‌فاصله و نشانه‌گذاری را درست کن و عددها را با رقم بنویس. "
                 "لحن و کلمه‌های گوینده را عوض نکن؛ اگر محاوره‌ای حرف زده، محاوره‌ای بماند.",
    "رسمی": "متن را به فارسی نوشتاری رسمی و مؤدبانه بازنویسی کن (مثلاً «می‌خواهم» نه «می‌خوام»)، با نیم‌فاصله و نشانه‌گذاری درست.",
    "خودمانی": "متن را به فارسی محاوره‌ای و خودمانی بنویس، همان‌طور که در پیام به دوست می‌نویسند (مثلاً «می‌خوام»، «میام»)، با نیم‌فاصله درست.",
    "خلاصه": "خلاصه‌ی کوتاه و روان متن را به فارسی نوشتاری بنویس که همه‌ی نکته‌های اصلی (زمان، عدد، نام، درخواست) را داشته باشد. "
             "اگر متن خودش کوتاه است، فقط آن را کوتاه‌تر و مرتب کن.",
}
TESTS = [
    "سلام فردا ساعت پنج میام دفتر نه ببخشید ساعت شش میام که با هم صحبت کنیم",
    "میخواستم بگم که گزارش رو تا آخر هفته میفرستم البته اگه داده ها برسه",
    "لطفا دو کیلو گوجه و یه بسته نون بگیر یعنی نه نون نمیخواد شیر بگیر",
    "جلسه ی امروز به خاطر مشکل فنی کنسل شد و هفته بعد برگذار میشه",
    "من دیروز رفتم بانک ولی بسته بود چون تعتیل رسمی بود",
    "قیمت دلار امروز دوباره بالا رفت و خیلی از مغازه ها قیمت هارو عوض کردن",
    "ازتون ممنونم بابت کمکتون واقعا بدون شما نمیتونستم این پروژه رو تموم کنم",
    "بچه ها یادتون نره فردا امتهان ریاضی داریم کتاب و ماشین حساب بیارین",
    "شرکت ما در سال گذشته حدود بیست درصد رشد داشت و امسال قصد داریم دفتر جدیدی در شیراز باز کنیم که البته هنوز قطعی نیست و بستگی به بودجه داره",
    "اگه میشه یه تاکسی برام بگیر برای ساعت هفت صبح به فرودگاه امام",
    "خب ببین من فکر میکنم که ما باید اول مشکل سرور رو حل کنیم بعد بریم سراغ طراحی جدید چون الان کاربرا خیلی شکایت دارن",
    "دکتر گفت روزی سه بار بعد از غذا این قرص رو بخورم و تا ده روز ادامه بدم",
    "توی جلسه قرار شد که علی مسئول بخش فروش بشه و مریم هم کارای مالی رو انجام بده",
    "من فکر میکنم این فیلم خیلی قشنگ بود مخصوصا موسیقیش که کار یه آهنگساز جوون بود",
    "پرواز تهران به مشهد ساعت ده و نیم شب از فرودگاه مهرآباد حرکت میکنه",
    "یادم باشه فردا به مامان زنگ بزنم و تولدشو تبریک بگم",
]


def ask(text, style):
    body = {"messages": [{"role": "system", "content": COMMON + " " + STYLES[style]}, {"role": "user", "content": text}],
            "temperature": 0.3, "top_p": 0.9, "max_tokens": 400}
    req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=600))
    return r["choices"][0]["message"]["content"].strip(), r["usage"]["completion_tokens"]


jobs = [(t, s) for t in TESTS for s in STYLES]
t = time.time()
with ThreadPoolExecutor(64) as ex:
    results = list(ex.map(lambda j: ask(*j), jobs))
dt = time.time() - t
tokens = sum(n for _, n in results)
summary.append(log(f"{len(jobs)} requests, {SLOTS} slots: {dt:.0f} s, {tokens} output tokens, {tokens / dt:.0f} tokens/s"))
t = time.time()
one, n1 = ask(TESTS[8], "رسمی")
summary.append(log(f"single request: {n1 / (time.time() - t):.0f} tokens/s"))

summary.append("--- samples")
for i, text in enumerate(TESTS):
    summary.append(f"\nورودی: {text}")
    for j, style in enumerate(STYLES):
        summary.append(f"[{style}] {results[i * len(STYLES) + j][0]}")
summary.append(f"\nminutes {(time.time() - T0) / 60:.0f}")
server.terminate()
open(f"{OUT}/summary.txt", "w", encoding="utf-8").write("\n".join(summary) + "\n")
print("\n".join(summary))
