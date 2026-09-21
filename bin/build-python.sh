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
# --no-cache: don't write uv's wheel cache into the slug (it would otherwise ship in the image).
# packaging: imported by ibis.backends.postgres but declared by neither ibis nor nao-core. It used
# to come in through pytest, which upstream moved out of the core deps; '.[all]' still pulls it
# transitively, our trimmed extras don't.
uv pip install --no-cache --python "$PY" ".[${EXTRAS}]" packaging

# Fail the build (the running version stays up) rather than ship an instance that cannot query
# its database: nao reports any ImportError of a backend as "driver missing", hiding the cause.
"$PY" - "$EXTRAS" <<'PY'
import importlib
import sys

from nao_core.deps import _EXTRAS

failures = []
for extra in sys.argv[1].split(","):
    for module in _EXTRAS.get(extra, []):
        try:
            importlib.import_module(module)
        except Exception as error:
            failures.append(f"{extra}: {module} -> {type(error).__name__}: {error}")

if failures:
    sys.exit("[build-python] extras not importable:\n  " + "\n  ".join(failures))
print("[build-python] all extras importable")
PY
