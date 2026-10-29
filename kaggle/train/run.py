# Fine-tunes the Mana Piper voice (MahtaFetrat, MIT) on Mana-TTS with the app's own phonemes
# (kaggle/prep output, ids from mana.onnx.json, so the app's PiperVoice needs no change). One GPU,
# stops itself before Kaggle's 12 h limit, then writes the last checkpoint and mana.onnx to
# /kaggle/working. The next session starts from the checkpoint in the dataset keyless-voice-ckpt
# when that is attached, otherwise from Mana's own checkpoint on Hugging Face.
import glob, json, os, shutil, subprocess, sys, time

HOURS = float(os.environ.get("HOURS", "10.5"))
OUT = "/kaggle/working"


def sh(cmd, check=True):
    print(f"$ {cmd}", flush=True)
    return subprocess.run(cmd, shell=True, check=check)


sh("nvidia-smi --query-gpu=name,memory.total --format=csv")
sh("git clone -q --depth 1 https://github.com/OHF-voice/piper1-gpl.git /kaggle/temp/piper")
sh("pip install -q scikit-build cmake ninja")
sh("cd /kaggle/temp/piper && pip install -q -e '.[train]' && bash ./build_monotonic_align.sh")
sh("cd /kaggle/temp/piper && python setup.py build_ext --inplace -q", check=False)

meta = glob.glob("/kaggle/input/**/metadata.csv", recursive=True)
assert meta, "attach the output of keyless-voice-prep"
data = os.path.dirname(meta[0])

# Utterances up to MAX_S seconds: the longest ones ran a T4 (15 GB) out of memory at batch 24.
import soundfile as sf

MAX_S = 10.0
rows = open(meta[0], encoding="utf-8").read().splitlines()
kept = [r for r in rows if sf.info(f"{data}/wavs/{r.split('|', 1)[0]}").duration <= MAX_S]
csv = "/kaggle/temp/metadata.csv"
open(csv, "w", encoding="utf-8").write("\n".join(kept) + "\n")
print("data", data, len(rows), "rows,", len(kept), f"up to {MAX_S} s", flush=True)

resume = sorted(glob.glob("/kaggle/input/**/*.ckpt", recursive=True), key=os.path.getmtime)
if resume:
    ckpt = resume[-1]
else:
    from huggingface_hub import hf_hub_download

    ckpt = hf_hub_download("MahtaFetrat/Mana-Persian-Piper", "ckpt/epoch=6012-step=4203520.ckpt")
print("start from", ckpt, flush=True)

# Mana's checkpoint comes from the old piper_train (Lightning 1.7): its hyperparameters and loop
# state do not parse in piper1-gpl, so the run starts from its weights, optimizer and step only.
import torch

c = torch.load(ckpt, map_location="cpu", weights_only=False)
keep = ("state_dict", "optimizer_states", "lr_schedulers", "epoch", "global_step", "pytorch-lightning_version")
start_ckpt = "/kaggle/temp/start.ckpt"
torch.save({k: c[k] for k in keep if k in c}, start_ckpt)
del c

import urllib.request

phonemes = "/kaggle/temp/phonemes.json"
urllib.request.urlretrieve("https://github.com/nikpendar/STTS/releases/download/tts-fa-mana/mana.onnx.json", "/kaggle/temp/mana.onnx.json")
json.dump(json.load(open("/kaggle/temp/mana.onnx.json"))["phoneme_id_map"], open(phonemes, "w"), ensure_ascii=False)

hh = int(HOURS)
mm = int((HOURS - hh) * 60)
# Lightning loads --ckpt_path with weights_only=True, which refuses Mana's checkpoint (it holds
# pathlib paths in its hyperparameters). Both checkpoints used here are trusted: Mana's own and ours.
launcher = "/kaggle/temp/train_main.py"
with open(launcher, "w") as f:
    f.write(
        "import functools, runpy, torch\n"
        "_load = torch.load\n"
        "@functools.wraps(_load)\n"
        "def load(*a, **k):\n"
        "    k['weights_only'] = False\n"
        "    return _load(*a, **k)\n"
        "torch.load = load\n"
        "import sys\n"
        "module = sys.argv.pop(1)\n"
        "runpy.run_module(module, run_name='__main__', alter_sys=True)\n"
    )
base = (
    f"cd /kaggle/temp/piper && python {launcher} piper.train fit"
    " --data.voice_name fa_IR-keyless"
    f" --data.csv_path {csv} --data.audio_dir {data}/wavs"
    " --data.dataset_type phoneme_ids --data.num_symbols 256 --data.espeak_voice fa"
    f" --data.phonemes_path {phonemes}"
    " --model.sample_rate 22050"
    " --data.cache_dir /kaggle/temp/cache"
    f" --data.config_path {OUT}/mana.onnx.json"
    " --data.batch_size 16 --data.num_workers 4 --data.trim_silence false"
    " --trainer.devices 1 --trainer.max_epochs 100000"
    f" --trainer.default_root_dir {OUT}/train"
    # A checkpoint every 1000 steps, so a crash or the time limit loses at most that much.
    " --trainer.callbacks+=lightning.pytorch.callbacks.ModelCheckpoint"
    f" --trainer.callbacks.dirpath {OUT}/train/steps --trainer.callbacks.every_n_train_steps 1000"
    " --trainer.callbacks.save_top_k 1 --trainer.callbacks.save_last true"
)
os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"
start = time.time()
sh(f"{base} --trainer.max_time 00:{hh:02d}:{mm:02d}:00 --ckpt_path {start_ckpt}", check=False)
if not glob.glob(f"{OUT}/train/**/*.ckpt", recursive=True) and time.time() - start < 1800:
    # Resuming the old training state failed: start a new run from the weights alone.
    left = HOURS - (time.time() - start) / 3600
    lh, lm = int(left), int((left - int(left)) * 60)
    print("resume failed; warm start from the weights", flush=True)
    sh(f"{base} --trainer.max_time 00:{lh:02d}:{lm:02d}:00 --model.warmstart_ckpt {start_ckpt}", check=False)
print(f"training {(time.time() - start) / 3600:.2f} h", flush=True)

ckpts = sorted(glob.glob(f"{OUT}/train/**/*.ckpt", recursive=True), key=os.path.getmtime)
assert ckpts, "no checkpoint written"
last = ckpts[-1]
print("last", last, flush=True)
shutil.copy(last, f"{OUT}/last.ckpt")
for c in ckpts:
    os.remove(c)
sh(f"cd /kaggle/temp/piper && python {launcher} piper.train.export_onnx --checkpoint {OUT}/last.ckpt --output-file {OUT}/mana.onnx")
sh(f"ls -la {OUT}; du -sh {OUT}")
