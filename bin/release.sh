#!/usr/bin/env bash
# Phase `release` Scalingo : joue les migrations Drizzle AVANT que la nouvelle version passe en ligne.
# Gating du déploiement (un échec migration annule la mise en ligne). Idempotent : `serve` les re-joue au boot.
set -euo pipefail
cd "$(dirname "$0")/.."

export DB_URI="${SCALINGO_POSTGRESQL_URL:-${DB_URI:-${DATABASE_URL:?aucune URL de base de données}}}"
cd apps/backend
exec bun scripts/db.migrate.ts
