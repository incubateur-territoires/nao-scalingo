#!/usr/bin/env bash
# Installe le CLI nao Python (cli/.[all]) + ses deps (FastAPI, uvicorn, ibis, providers LLM
# dont mistralai/anthropic/openai). Reproduit le stage `python-builder` du Dockerfile amont :
#   uv pip install --system '.[all]'
# Le python-buildpack a déjà provisionné Python 3.12 (+ uv via requirements.txt).
set -euo pipefail
cd "$(dirname "$0")/.."

# uv : fourni par requirements.txt (python-buildpack). Fallback installeur officiel si absent.
if ! command -v uv >/dev/null 2>&1; then
  export PATH="$HOME/.local/bin:$PATH"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

PY="$(command -v python3 || command -v python)"
echo "[build-python] uv=$(command -v uv) python=$PY ($($PY --version 2>&1))"

cd cli
# Override optionnel de la version du CLI (épingler sur la même release que l'app).
if [ -n "${NAO_CLI_VERSION:-}" ]; then
  sed -i -E "s/^version = .*/version = \"${NAO_CLI_VERSION}\"/" pyproject.toml || true
fi

# Install only the backends actually needed (keeps the slug under Scalingo's 2 GiB limit).
# Override per product via NAO_CLI_EXTRAS, e.g. "postgres,bigquery,anthropic".
# '.[all]' pulls every DB connector (snowflake, databricks, bigquery, mssql…) and blows up the slug.
EXTRAS="${NAO_CLI_EXTRAS:-postgres,anthropic,mistral,openai}"
echo "[build-python] installing nao-core extras: $EXTRAS"
# Target the exact interpreter provisioned by the buildpack (= the runtime one), no venv ambiguity.
uv pip install --python "$PY" ".[${EXTRAS}]"
