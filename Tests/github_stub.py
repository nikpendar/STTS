#!/usr/bin/env python3
"""A stand-in for the parts of the GitHub API the app's training feature uses (PersonalModel),
for the live simulator test: creating files (corrections), reading status.json, the latest
release and downloading its asset, which redirects to another host as GitHub's does, and
rejects the token there as GitHub's storage does.

    github_stub.py <data dir> [--port 8765] [--token test-token]

Files the app creates land in <data dir>/<path>. To publish a model, put <data dir>/release/
model.mlmodel and <data dir>/release/release.json (the JSON the training workflow writes into a
release's description).
"""
import argparse
import base64
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument("data")
parser.add_argument("--port", type=int, default=8765)
parser.add_argument("--token", default="test-token")
args = parser.parse_args()
DATA = os.path.abspath(args.data)


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body=b"", content_type="application/json", headers=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        if self.headers.get("Authorization") == f"Bearer {args.token}":
            return True
        self.reply(401, b'{"message":"Bad credentials"}')
        return False

    def repo_path(self):
        parts = self.path.split("?")[0].split("/")
        # /repos/<owner>/<name>/<rest>
        return "/".join(parts[4:]) if len(parts) > 4 and parts[1] == "repos" else None

    def do_PUT(self):
        rest = self.repo_path()
        if not self.authorized():
            return
        if not rest or not rest.startswith("contents/"):
            return self.reply(404)
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        target = os.path.join(DATA, rest[len("contents/"):])
        if os.path.exists(target):
            return self.reply(422, b'{"message":"sha wasn\'t supplied"}')
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(base64.b64decode(body["content"]))
        print("created", rest, os.path.getsize(target), "bytes", flush=True)
        self.reply(201, b'{"content":{}}')

    def do_GET(self):
        if self.path.startswith("/download/"):
            # GitHub's storage host: a token here is an error.
            if self.headers.get("Authorization"):
                return self.reply(400, b"Only one auth mechanism allowed")
            with open(os.path.join(DATA, "release", "model.mlmodel"), "rb") as f:
                data = f.read()
            print("asset downloaded", len(data), "bytes", flush=True)
            return self.reply(200, data, "application/octet-stream")
        rest = self.repo_path()
        if not self.authorized():
            return
        if rest == "contents/status.json":
            path = os.path.join(DATA, "status.json")
            if not os.path.exists(path):
                return self.reply(404)
            return self.reply(200, open(path, "rb").read())
        if rest == "releases/latest":
            path = os.path.join(DATA, "release", "release.json")
            if not os.path.exists(path):
                return self.reply(404, b'{"message":"Not Found"}')
            port = self.server.server_address[1]
            release = {
                "tag_name": "v1",
                "body": open(path, encoding="utf-8").read(),
                "assets": [{"name": "Koochik-personal.mlmodel",
                            "url": f"http://127.0.0.1:{port}/repos/stub/repo/releases/assets/1"}],
            }
            return self.reply(200, json.dumps(release).encode())
        if rest == "releases/assets/1":
            port = self.server.server_address[1]
            return self.reply(302, headers={"Location": f"http://localhost:{port}/download/1"})
        self.reply(404)


print("GitHub stand-in on port", args.port, flush=True)
ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
