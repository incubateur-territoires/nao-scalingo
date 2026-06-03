#!/usr/bin/env bash
# Orchestrateur de build, appelé par `heroku-postbuild` (hook du bun-buildpack).
# Reproduit les stages du Dockerfile amont : deps Python (uv) + deps JS (bun) + build frontend.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== [build] 1/2 Python CLI (sidecar FastAPI) ==="
bash bin/build-python.sh

echo "=== [build] 2/4 JS deps + frontend (bun) ==="
bash bin/build-js.sh

echo "=== [build] 3/4 élagage des devDependencies (inutiles au runtime) ==="
# Le frontend est déjà buildé (apps/frontend/dist) et le backend tourne en TS via bun :
# vite / esbuild / typescript / eslint & co ne servent plus au runtime.
du -sh node_modules 2>/dev/null | sed 's/^/[build] node_modules avant prune: /' || true
HUSKY=0 bun install --production --ignore-scripts || echo "ℹ prune devDeps échouée (non bloquant)"

echo "=== [build] 4/4 nettoyage caches (réduction du slug) ==="
# Caches inutiles au runtime mais embarqués dans le slug. On NE touche PAS à .heroku/bin (binaire bun).
rm -rf \
  .heroku/cache \
  "${HOME:-.}/.cache" .cache \
  node_modules/.cache \
  apps/frontend/.vite \
  cli/tests \
  2>/dev/null || true
du -sh node_modules 2>/dev/null | sed 's/^/[build] node_modules: /' || true

echo "=== [build] terminé ==="
