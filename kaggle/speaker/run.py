# Pilot: the app's voice (the session-3 checkpoint, Mana Piper fine-tuned with the app's phonemes)
# fine-tuned on a new speaker's recordings (private dataset keyless-voice-speaker1: wavs at
# 22050 Hz and metadata.csv "name|ipa|ids", made by scripts/speaker and sealed in voice-data/).
# With minutes of audio the voice overfits quickly, so checkpoints are kept every 250 batches and a
# few are exported as voice-<batches>.onnx to /kaggle/working for a listening choice.
import glob, json, os, shutil, signal, subprocess, sys, time

T0 = time.time()
BUDGET_H = float(os.environ.get("BUDGET_H", "3.5"))
MAX_STEPS = int(os.environ.get("MAX_STEPS", "8000"))  # optimizer steps: two per batch
EXPORT = [500, 1000, 1500, 2000, 3000, 4000, 6000, 8000]
START_STEP = 42000  # the session-3 checkpoint, the voice in the app
OUT = "/kaggle/working"
USER = "KAGGLE_USER"  # set by kaggle-run.yml


def sh(cmd, check=True, timeout=None):
    print(f"[{(time.time() - T0) / 3600:.2f} h] $ {cmd}", flush=True)
    p = subprocess.Popen(cmd, shell=True, start_new_session=True)
    try:
        p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"[{(time.time() - T0) / 3600:.2f} h] stopped at the time budget", flush=True)
        os.killpg(p.pid, signal.SIGINT)
        try:
            p.wait(timeout=180)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
    if check and p.returncode:
        raise subprocess.CalledProcessError(p.returncode, cmd)


sh("nvidia-smi --query-gpu=name,memory.total --format=csv")
sh("git clone -q --depth 1 https://github.com/OHF-voice/piper1-gpl.git /kaggle/temp/piper")
sh("pip install -q scikit-build cmake ninja")
sh("cd /kaggle/temp/piper && pip install -q -e '.[train]' && bash ./build_monotonic_align.sh")
sh("cd /kaggle/temp/piper && python setup.py build_ext --inplace -q", check=False)

meta = [m for m in glob.glob("/kaggle/input/**/metadata.csv", recursive=True) if "speaker" in m]
assert meta, "attach the dataset keyless-voice-speaker1"
audio = os.path.dirname(meta[0])
rows = open(meta[0], encoding="utf-8").read().splitlines()
print("speaker data", audio, len(rows), "utterances", flush=True)

import torch


def step_of(path):
    return torch.load(path, map_location="cpu", weights_only=False).get("global_step")


# The dataset's newest version is session 4, which read worse: look for session 3 among the versions.
ckpt = None
try:
    import kagglehub

    for version in (3, 2, 4, 1):
        try:
            d = kagglehub.dataset_download(f"{USER}/keyless-voice-ckpt/versions/{version}")
        except Exception as e:
            print("version", version, "not available:", e, flush=True)
            continue
        found = glob.glob(f"{d}/**/*.ckpt", recursive=True)
        step = step_of(found[0]) if found else None
        print("version", version, found, "step", step, flush=True)
        if step == START_STEP:
            ckpt = found[0]
            break
        if found:
            os.remove(found[0])
except Exception as e:
    print("kagglehub failed:", e, flush=True)
if ckpt is None:
    attached = glob.glob("/kaggle/input/**/*.ckpt", recursive=True)
    assert attached, "no checkpoint"
    ckpt = attached[0]
    print("::warning:: session 3 not found; starting from the attached checkpoint, step", step_of(ckpt), flush=True)
print("start from", ckpt, flush=True)

c = torch.load(ckpt, map_location="cpu", weights_only=False)
keep = ("state_dict", "optimizer_states", "lr_schedulers", "epoch", "global_step", "pytorch-lightning_version")
start_ckpt = "/kaggle/temp/start.ckpt"
torch.save({k: c[k] for k in keep if k in c}, start_ckpt)
del c

import urllib.request

phonemes = "/kaggle/temp/phonemes.json"
urllib.request.urlretrieve("https://github.com/nikpendar/STTS/releases/download/tts-fa-keyless/mana.onnx.json", "/kaggle/temp/mana.onnx.json")
json.dump(json.load(open("/kaggle/temp/mana.onnx.json"))["phoneme_id_map"], open(phonemes, "w"), ensure_ascii=False)

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
        "_export = torch.onnx.export\n"
        "torch.onnx.export = functools.wraps(_export)(lambda *a, **k: _export(*a, **{**k, 'dynamo': False}))\n"
        "import sys\n"
        "module = sys.argv.pop(1)\n"
        "runpy.run_module(module, run_name='__main__', alter_sys=True)\n"
    )
base = (
    f"cd /kaggle/temp/piper && python {launcher} piper.train fit"
    " --data.voice_name fa_IR-keyless-speaker"
    f" --data.csv_path {meta[0]} --data.audio_dir {audio}"
    " --data.dataset_type phoneme_ids --data.num_symbols 256 --data.espeak_voice fa"
    f" --data.phonemes_path {phonemes}"
    " --model.sample_rate 22050"
    " --data.cache_dir /kaggle/temp/cache"
    f" --data.config_path {OUT}/mana.onnx.json"
    " --data.batch_size 16 --data.num_workers 2 --data.trim_silence false"
    # Nearly every utterance trains: three are held out to watch the validation loss.
    " --data.validation_split 0.04 --data.num_test_examples 0"
    f" --trainer.devices 1 --trainer.max_epochs 100000 --trainer.max_steps {MAX_STEPS}"
    " --trainer.log_every_n_steps 5"
    # No validation: piper's own checkpoint callbacks stop the run when their metric is missing.
    " --trainer.limit_val_batches 0 --model.mos_metric none"
    f" --trainer.default_root_dir {OUT}/train"
    " --trainer.callbacks+=lightning.pytorch.callbacks.ModelCheckpoint"
    f" --trainer.callbacks.dirpath /kaggle/temp/steps --trainer.callbacks.every_n_train_steps 500"
    " --trainer.callbacks.filename step-{step} --trainer.callbacks.save_top_k -1 --trainer.callbacks.save_last true"
)
os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"
left = lambda: BUDGET_H * 3600 - (time.time() - T0)
start = time.time()
sh(f"{base} --ckpt_path {start_ckpt}", check=False, timeout=left())
if not glob.glob("/kaggle/temp/steps/*.ckpt") and time.time() - start < 1500:
    print("resume failed; warm start from the weights", flush=True)
    sh(f"{base} --model.warmstart_ckpt {start_ckpt}", check=False, timeout=left())
print(f"training {(time.time() - start) / 3600:.2f} h", flush=True)

found = {}
for path in glob.glob("/kaggle/temp/steps/*.ckpt"):
    try:
        found[step_of(path)] = path
    except Exception as e:
        print("unreadable", path, e, flush=True)
print("checkpoints at steps", sorted(found), flush=True)
assert found, "no checkpoint written"
wanted = [s for s in EXPORT if s in found] or [max(found)]
if max(found) not in wanted:
    wanted.append(max(found))
for step in wanted:
    # Named by batches (two optimizer steps each).
    sh(f"cd /kaggle/temp/piper && python {launcher} piper.train.export_onnx --checkpoint {found[step]} --output-file {OUT}/voice-{step // 2:05d}.onnx", check=False)
shutil.rmtree(f"{OUT}/train", ignore_errors=True)
sh(f"ls -la {OUT}; du -sh {OUT}")
