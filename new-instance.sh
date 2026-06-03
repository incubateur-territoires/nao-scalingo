#!/usr/bin/env bash
#
# Provisionne et déploie une instance nao dédiée à un produit sur Scalingo.
# Une instance = une app + sa base PostgreSQL + son repo de contexte + sa clé LLM (données isolées).
#
# Pré-requis : CLI scalingo installée et authentifiée (`scalingo login`), accès région secnum activé.
#
# Usage :
#   NAO_CONTEXT_GIT_URL=https://github.com/incubateur-territoires/contexte-<produit>.git \
#   ANTHROPIC_API_KEY=sk-ant-... \
#   ./new-instance.sh <produit>
#
# Variables d'environnement reconnues :
#   NAO_CONTEXT_GIT_URL      (requis)  repo de contexte du produit
#   ANTHROPIC_API_KEY        (ou MISTRAL_API_KEY / OPENAI_API_KEY) clé LLM du produit
#   NAO_CONTEXT_GIT_BRANCH   (def. main)
#   NAO_CONTEXT_GIT_SUBPATH  (opt.)    sous-dossier du repo de contexte
#   NAO_CONTEXT_GIT_TOKEN    (opt.)    PAT si repo de contexte privé
#   SCALINGO_REGION          (def. osc-secnum-fr1)
#   PG_PLAN                  (def. postgresql-starter-512)
#   WEB_SIZE                 (def. M)
set -euo pipefail

PRODUCT="${1:?usage: ./new-instance.sh <produit>}"
APP="nao-${PRODUCT}"
REGION="${SCALINGO_REGION:-osc-secnum-fr1}"
PG_PLAN="${PG_PLAN:-postgresql-starter-512}"
WEB_SIZE="${WEB_SIZE:-M}"
: "${NAO_CONTEXT_GIT_URL:?définis NAO_CONTEXT_GIT_URL (repo de contexte du produit)}"

# Clé(s) LLM optionnelles : peuvent aussi être configurées via l'interface de Nao (stockées en base).
LLM_KEY=""
[ -n "${ANTHROPIC_API_KEY:-}" ] && LLM_KEY="ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
[ -n "${MISTRAL_API_KEY:-}" ]   && LLM_KEY="${LLM_KEY} MISTRAL_API_KEY=${MISTRAL_API_KEY}"
[ -n "${OPENAI_API_KEY:-}" ]    && LLM_KEY="${LLM_KEY} OPENAI_API_KEY=${OPENAI_API_KEY}"
[ -z "$LLM_KEY" ] && echo "ℹ Aucune clé LLM en env — à configurer via l'interface de Nao."

sc() { scalingo --region "$REGION" --app "$APP" "$@"; }

echo "=== 1/5 Création de l'app $APP ($REGION) ==="
scalingo --region "$REGION" create "$APP"

echo "=== 2/5 Addon PostgreSQL ($PG_PLAN) ==="
sc addons-add postgresql "$PG_PLAN"

echo "=== 3/5 Variables d'environnement ==="
# DB_URI n'est PAS défini : bin/web.sh le dérive de SCALINGO_POSTGRESQL_URL (auto-roté par l'addon).
# shellcheck disable=SC2086
sc env-set \
  MODE=prod \
  NODE_ENV=production \
  HUSKY=0 \
  FASTAPI_PORT=8005 \
  NAO_CONTEXT_SOURCE=git \
  NAO_CONTEXT_GIT_URL="$NAO_CONTEXT_GIT_URL" \
  NAO_CONTEXT_GIT_BRANCH="${NAO_CONTEXT_GIT_BRANCH:-main}" \
  NAO_CONTEXT_GIT_SUBPATH="${NAO_CONTEXT_GIT_SUBPATH:-}" \
  NAO_CONTEXT_GIT_TOKEN="${NAO_CONTEXT_GIT_TOKEN:-}" \
  BETTER_AUTH_SECRET="$(openssl rand -hex 32)" \
  BETTER_AUTH_URL="https://${APP}.${REGION}.scalingo.io" \
  $LLM_KEY

echo "=== 4/5 Remote git Scalingo ==="
sc git-setup --remote "scalingo-${APP}"

echo "=== 5/5 Déploiement (push de la branche courante) ==="
git push "scalingo-${APP}" HEAD:master

echo
echo "✓ Instance déployée : https://${APP}.${REGION}.scalingo.io"
echo "  Logs   : scalingo --region $REGION --app $APP logs -f"
echo "  Config : scalingo --region $REGION --app $APP env"
