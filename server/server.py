#!/usr/bin/env python3
"""Personal training server for PersianSTT, meant to run on a Mac on the same network.

The phone sends each dictation the user corrected: the recording and the corrected text.
Once enough new samples have arrived (or on request), train.py fine-tunes the model on all
of them and publishes a new ggml model only if it transcribes the user's held-out samples
better than the base. The app's settings page checks /model/latest and downloads it.

    python3 server.py [--port 8765] [--data ./data] [--min-new 20] [--base <model>] [--train-args "..."]

Endpoints
    POST /samples            {"id", "original", "corrected", "audio": base64 WAV (16 kHz mono)}
    GET  /status             sample counts, training state, latest model
    POST /train              start training now
    GET  /model/latest       {"version", "size", "sha256", "wer_before", "wer_after", ...}
    GET  /model/<version>    the ggml model file
"""
import argparse
import base64
import hashlib
import json
import os
import re
import shlex
import socketserver
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent


class State:
    def __init__(self, data: Path, min_new: int, train_args):
        self.data = data
        self.train_args = train_args
        self.samples = data / "samples"
        self.models = data / "models"
        self.samples.mkdir(parents=True, exist_ok=True)
        self.models.mkdir(parents=True, exist_ok=True)
        self.min_new = min_new
        self.lock = threading.Lock()
        self.training = False
        self.last_log = ""

    def sample_ids(self):
        return sorted(p.stem for p in self.samples.glob("*.json"))

    def latest(self):
        path = self.models / "latest.json"
        return json.loads(path.read_text()) if path.exists() else None

    def trained_count(self):
        latest = self.latest() or {}
        marker = self.data / "last_train.json"
        if marker.exists():
            return json.loads(marker.read_text()).get("samples", 0)
        return latest.get("samples", 0)

    def save_sample(self, body):
        sample_id = re.sub(r"[^A-Za-z0-9_-]", "", str(body.get("id", "")))[:64]
        corrected = str(body.get("corrected", "")).strip()
        audio = base64.b64decode(body.get("audio", ""), validate=True)
        if not sample_id or not corrected or len(audio) < 1000 or audio[:4] != b"RIFF":
            raise ValueError("id, corrected and a WAV audio are required")
        (self.samples / f"{sample_id}.wav").write_bytes(audio)
        meta = {"id": sample_id, "original": str(body.get("original", "")), "corrected": corrected,
                "received": time.strftime("%Y-%m-%dT%H:%M:%S")}
        (self.samples / f"{sample_id}.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))
        return len(self.sample_ids())

    def start_training(self, reason):
        with self.lock:
            if self.training:
                return False
            self.training = True
        threading.Thread(target=self._train, args=(reason,), daemon=True).start()
        return True

    def _train(self, reason):
        count = len(self.sample_ids())
        print(f"training on {count} samples ({reason})", flush=True)
        log_path = self.data / "train.log"
        try:
            with open(log_path, "w") as log:
                code = subprocess.call([sys.executable, str(HERE / "train.py"), "--data", str(self.data),
                                        *self.train_args], stdout=log, stderr=subprocess.STDOUT)
            self.last_log = log_path.read_text()[-4000:]
            (self.data / "last_train.json").write_text(json.dumps({"samples": count, "code": code,
                                                                     "time": time.time()}))
            print(f"training finished with code {code}; see {log_path}", flush=True)
        finally:
            with self.lock:
                self.training = False

    def auto_train_loop(self):
        while True:
            time.sleep(60)
            new = len(self.sample_ids()) - self.trained_count()
            if self.min_new > 0 and new >= self.min_new:
                self.start_training(f"{new} new samples")


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer looks up the machine's full DNS name here, which stalled startup on a Mac
        # until clients timed out; the name is not needed.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", self.server_address[1]


def make_handler(state: State):
    class Handler(BaseHTTPRequestHandler):
        def _json(self, code, payload):
            data = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/status":
                ids = state.sample_ids()
                return self._json(200, {"samples": len(ids), "trained_on": state.trained_count(),
                                        "training": state.training, "min_new": state.min_new,
                                        "latest": state.latest(), "log_tail": state.last_log[-1500:]})
            if self.path == "/model/latest":
                latest = state.latest()
                return self._json(200, latest) if latest else self._json(404, {"error": "no model yet"})
            match = re.fullmatch(r"/model/(\d+)", self.path)
            if match:
                latest = state.latest()
                path = state.models / f"ggml-personal-v{match.group(1)}.bin"
                if not path.exists():
                    return self._json(404, {"error": "unknown version"})
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(path.stat().st_size))
                self.end_headers()
                with open(path, "rb") as f:
                    while chunk := f.read(1 << 20):
                        self.wfile.write(chunk)
                return
            self._json(404, {"error": "not found"})

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            if length > 50 << 20:
                return self._json(413, {"error": "too large"})
            raw = self.rfile.read(length) if length else b""
            if self.path == "/samples":
                try:
                    count = state.save_sample(json.loads(raw))
                except (ValueError, json.JSONDecodeError) as error:
                    return self._json(400, {"error": str(error)})
                return self._json(200, {"ok": True, "samples": count})
            if self.path == "/train":
                started = state.start_training("requested")
                return self._json(200, {"started": started, "training": True})
            self._json(404, {"error": "not found"})

        def log_message(self, fmt, *args):
            print(f"{self.address_string()} {fmt % args}", flush=True)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--data", type=Path, default=HERE / "data")
    parser.add_argument("--min-new", type=int, default=20,
                        help="train automatically after this many new samples (0 = only on request)")
    parser.add_argument("--base", help="model to fine-tune (Hugging Face id or folder; default: train.py's)")
    parser.add_argument("--train-args", default="", help='more options for train.py, e.g. "--epochs 5"')
    args = parser.parse_args()
    train_args = (["--base", args.base] if args.base else []) + shlex.split(args.train_args)
    state = State(args.data.resolve(), args.min_new, train_args)
    threading.Thread(target=state.auto_train_loop, daemon=True).start()
    server = Server(("0.0.0.0", args.port), make_handler(state))
    try:
        host = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True,
                              timeout=5).stdout.strip() if sys.platform == "darwin" else os.uname().nodename
    except subprocess.TimeoutExpired:
        host = os.uname().nodename
    print(f"PersianSTT training server on http://{host}.local:{args.port}  (data: {state.data})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
