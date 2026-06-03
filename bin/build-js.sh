#!/usr/bin/env bash
# Deps JS (bun possède node_modules) + build du frontend. Reproduit les stages `deps` et
# `frontend-builder` du Dockerfile amont. Le backend n'a PAS besoin d'être buildé : bun
# exécute le TypeScript directement au runtime (cf. bin/web.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

# HUSKY=0 : neutralise le hook `prepare` (husky) qui n'a pas de sens dans un build CI.
export HUSKY=0

# --ignore-scripts comme le Dockerfile (évite les postinstall lourds/aléatoires),
# puis postinstall ciblé de @vscode/ripgrep (télécharge son binaire de plateforme).
bun install --ignore-scripts
( cd node_modules/@vscode/ripgrep && bun run postinstall ) || true

# Build du frontend → apps/frontend/dist (servi en statique par le backend).
( cd apps/frontend && bunx vite build )
