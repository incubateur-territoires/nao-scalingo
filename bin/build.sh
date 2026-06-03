#!/usr/bin/env bash
# Orchestrateur de build, appelé par `heroku-postbuild` (hook du bun-buildpack).
# Reproduit les stages du Dockerfile amont : deps Python (uv) + deps JS (bun) + build frontend.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== [build] 1/2 Python CLI (sidecar FastAPI) ==="
bash bin/build-python.sh

echo "=== [build] 2/2 JS deps + frontend (bun) ==="
bash bin/build-js.sh

echo "=== [build] terminé ==="
