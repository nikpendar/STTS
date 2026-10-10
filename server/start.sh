#!/usr/bin/env bash
# Starts the training server; options are passed on to server.py (see server.py --help).
cd "$(dirname "$0")"
. .venv/bin/activate
exec python3 server.py "$@"
