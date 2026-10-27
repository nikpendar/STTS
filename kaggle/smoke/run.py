# Kaggle smoke test for the Persian voice training: GPU, disk, piper1-gpl training install, the
# Mana checkpoint loads in it, and what a Mana-TTS parquet part holds.
import os, subprocess, sys, time


def sh(cmd):
    print(f"$ {cmd}", flush=True)
    subprocess.run(cmd, shell=True, check=False)


sh("nvidia-smi; df -h /kaggle/working /kaggle/temp /tmp 2>/dev/null; nproc; free -g")
t = time.time()
sh("git clone -q --depth 1 https://github.com/OHF-voice/piper1-gpl.git /tmp/piper")
sh("cd /tmp/piper && pip install -q -e '.[train]' 2>&1 | tail -3 && bash ./build_monotonic_align.sh 2>&1 | tail -2 && python setup.py build_ext --inplace 2>&1 | tail -1")
print(f"install {time.time() - t:.0f} s", flush=True)
sh("pip list 2>/dev/null | grep -iE '^(torch|lightning|pytorch-lightning|onnxruntime) '")
sh("cd /tmp/piper && python -m piper.train fit --help 2>&1 | grep -E 'data_type|phoneme|ckpt|batch_size|max_epochs|check_val|precision|num_workers|quality' | head -30")

from huggingface_hub import hf_hub_download

t = time.time()
ckpt = hf_hub_download("MahtaFetrat/Mana-Persian-Piper", "ckpt/epoch=6012-step=4203520.ckpt")
part = hf_hub_download("MahtaFetrat/Mana-TTS", "dataset/dataset_part_001.parquet", repo_type="dataset")
print(f"download {time.time() - t:.0f} s", flush=True)

import torch

c = torch.load(ckpt, map_location="cpu", weights_only=False)
print("ckpt keys", list(c.keys()))
print("hyper", {k: v for k, v in c.get("hyper_parameters", {}).items() if not isinstance(v, (list, dict))})
sd = c["state_dict"]
print("params", len(sd), "emb", [(k, tuple(v.shape)) for k, v in sd.items() if "emb" in k][:4])

sys.path.insert(0, "/tmp/piper/src")
try:
    from piper.train.vits.lightning import VitsModel  # piper1-gpl layout

    m = VitsModel.load_from_checkpoint(ckpt, map_location="cpu", weights_only=False)
    print("piper1-gpl loads the Mana checkpoint:", type(m).__name__)
except Exception as e:  # noqa: BLE001
    print("load_from_checkpoint failed:", repr(e)[:800])
    sh("ls /tmp/piper/src/piper/train /tmp/piper/src/piper/train/vits")

import pandas as pd

df = pd.read_parquet(part)
print(df.dtypes)
print(len(df), "rows; hours", df["duration"].sum() / 3600)
print(df["match_quality"].value_counts().head(), df["CER"].describe())
row = df.iloc[0]
print({k: (str(row[k])[:200]) for k in df.columns if k != "audio"})
a = row["audio"]
print("audio type", type(a), getattr(a, "dtype", None), len(a), "sr", row.get("samplerate"))
