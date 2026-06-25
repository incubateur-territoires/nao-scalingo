#!/usr/bin/env bash
#
# Gestion des instances nao sur Scalingo (création, déploiement, exploitation).
# Une instance = app "nao-<produit>" + PostgreSQL + repo de contexte + clé LLM (données isolées).
#
# Pré-requis : CLI scalingo installée et authentifiée (`scalingo login`), accès région secnum activé.
# Aide : ./nao-scalingo.sh help
#
# Principe : Scalingo est la SOURCE DE VÉRITÉ des variables d'env. `create` est idempotent
# (relit l'env déjà posé sur l'app) ; `deploy` ne touche JAMAIS à l'env (donc jamais à
# BETTER_AUTH_SECRET → pas de déconnexion des utilisateurs).
set -euo pipefail

# --- Réglages globaux (surchargeables par l'environnement) ---
REGION="${SCALINGO_REGION:-osc-secnum-fr1}"
PG_PLAN="${PG_PLAN:-postgresql-starter-512}"
WEB_SIZE="${WEB_SIZE:-L}"

SCRIPT_NAME="$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# État interne
PRODUCT=""
APP=""
APP_ENV=""
APP_ENV_LOADED=0
ASSUME_YES="${ASSUME_YES:-0}"
NO_PG=0
ENV_ARGS=()

# Temporaires de déploiement, nettoyés par cleanup() (trap EXIT).
DEPLOY_TMP_ROOT=""
DEPLOY_ARCHIVE=""
cleanup() {
  [ -n "${DEPLOY_TMP_ROOT:-}" ] && rm -rf "$DEPLOY_TMP_ROOT"
  [ -n "${DEPLOY_ARCHIVE:-}" ]  && rm -f  "$DEPLOY_ARCHIVE"
  return 0
}
trap cleanup EXIT

# --- Couleurs (désactivées hors TTY ou si NO_COLOR) ---
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_BOLD=''
fi

# =====================================================================================
# Dispatch
# =====================================================================================
main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
  esac
  require_scalingo
  case "$cmd" in
    create)         cmd_create "$@" ;;
    deploy|update)  cmd_deploy "$@" ;;
    set-env)        cmd_set_env "$@" ;;
    set-key)        cmd_set_key "$@" ;;
    list)           cmd_list ;;
    env)            cmd_env "$@" ;;
    logs)           cmd_logs "$@" ;;
    restart)        cmd_restart "$@" ;;
    status|ps)      cmd_status "$@" ;;
    scale)          cmd_scale "$@" ;;
    run)            cmd_run "$@" ;;
    open)           cmd_open "$@" ;;
    cache-clear)    cmd_cache_clear "$@" ;;
    destroy)        cmd_destroy "$@" ;;
    *)              usage_error "commande inconnue : $cmd" ;;
  esac
}

usage() {
  cat >&2 <<EOF
${C_BOLD}$SCRIPT_NAME${C_RESET} — gestion des instances nao sur Scalingo

${C_BOLD}USAGE${C_RESET}
  ./$SCRIPT_NAME <commande> [<produit>] [args...]

Une instance = app "nao-<produit>" + PostgreSQL + repo de contexte + clé LLM (données isolées).

${C_BOLD}COMMANDES${C_RESET}
  create  <produit> [--no-pg]   Provisionne tout : app + PostgreSQL + env + 1er déploiement.
                                Requiert NAO_CONTEXT_GIT_URL (en env ou déjà posé sur l'app).
                                Idempotent : ne régénère JAMAIS BETTER_AUTH_SECRET s'il existe.
                                --no-pg (ou DB_URI fourni) : saute l'addon PostgreSQL (DB externe).
  deploy  <produit>             Redéploie le HEAD courant de CE repo. NE TOUCHE PAS à l'env.
  update  <produit>             Alias de deploy.
  set-env <produit> K=V ...     Définit des variables d'env (refuse BETTER_AUTH_SECRET sans
                                --force-secret).
  set-key <produit>             Pose les clés LLM lues dans l'env (ANTHROPIC/MISTRAL/OPENAI_API_KEY).
  list                          Liste les apps nao-* de la région.
  env     <produit>             Affiche les variables d'env.
  logs    <produit>             Suit les logs (-f).
  restart <produit>             Redémarre l'app.
  status  <produit>             État des conteneurs (alias : ps).
  scale   <produit> <taille>    Redimensionne le web (S|M|L|XL|2XL).
  run     <produit> <cmd...>    Exécute une commande one-off dans le contexte de l'app.
  open    <produit>             Ouvre l'URL de l'app.
  cache-clear <produit>         Vide le cache de build (si Scalingo bloque sur python-only).
  destroy <produit> [--yes]     DÉTRUIT l'app + base (confirmation par saisie du nom).
  help                          Cette aide.

${C_BOLD}VARIABLES D'ENV (création)${C_RESET}
  NAO_CONTEXT_GIT_URL    (requis)  repo de contexte du produit
  ANTHROPIC_API_KEY | MISTRAL_API_KEY | OPENAI_API_KEY  (opt.) clé LLM
  NAO_CONTEXT_GIT_BRANCH (def. main)   NAO_CONTEXT_GIT_SUBPATH   NAO_CONTEXT_GIT_TOKEN
  DB_URI                 (opt.)    DB externe (implique --no-pg)
  SCALINGO_REGION (def. $REGION)   PG_PLAN (def. $PG_PLAN)   WEB_SIZE (def. $WEB_SIZE)

${C_BOLD}CUSTOMISATION PAR INSTANCE${C_RESET}
  Dépose des fichiers dans instances/<produit>/ : ils écrasent la base au déploiement
  (ex. instances/<produit>/Procfile pour un tunnel SSH). Code commité, pas de secrets dedans.

${C_BOLD}EXEMPLES${C_RESET}
  NAO_CONTEXT_GIT_URL=https://github.com/.../contexte-foo.git ANTHROPIC_API_KEY=sk-ant-... \\
    ./$SCRIPT_NAME create foo
  ./$SCRIPT_NAME deploy foo
  ./$SCRIPT_NAME set-key foo            # après ANTHROPIC_API_KEY=... en env
  ./$SCRIPT_NAME logs foo
EOF
}

# =====================================================================================
# Commandes
# =====================================================================================
cmd_create() {
  local product=""
  for a in "$@"; do
    case "$a" in
      --no-pg)   NO_PG=1 ;;
      --yes|-y)  ASSUME_YES=1 ;;
      -*)        usage_error "option inconnue : $a" ;;
      *)         product="$a" ;;
    esac
  done
  resolve_app "$product"

  if [ -z "${ANTHROPIC_API_KEY:-}${MISTRAL_API_KEY:-}${OPENAI_API_KEY:-}" ]; then
    info "Aucune clé LLM en env — à configurer plus tard (set-key) ou dans l'interface de nao."
  fi

  provision
  build_create_env
  step "Variables d'environnement"
  sc env-set "${ENV_ARGS[@]}"
  deploy_archive

  echo >&2
  ok "Instance prête : https://${APP}.${REGION}.scalingo.io"
  info "Logs   : ./$SCRIPT_NAME logs $PRODUCT"
  info "Config : ./$SCRIPT_NAME env $PRODUCT"
}

cmd_deploy() {
  resolve_app "${1:-}"
  deploy_archive
}

cmd_set_env() {
  local force_secret=0
  local -a rest=()
  for a in "$@"; do
    if [ "$a" = "--force-secret" ]; then force_secret=1; else rest+=("$a"); fi
  done
  resolve_app "${rest[0]:-}"
  local -a pairs=("${rest[@]:1}")
  [ "${#pairs[@]}" -gt 0 ] || usage_error "fournis au moins KEY=VAL"

  local p
  for p in "${pairs[@]}"; do
    case "$p" in
      *=*) ;;
      *) usage_error "format attendu KEY=VAL : $p" ;;
    esac
    [ -n "${p#*=}" ] || die "valeur vide interdite : $p (scalingo refuse VAR=)"
    case "$p" in
      BETTER_AUTH_SECRET=*)
        [ "$force_secret" = 1 ] || die "Refus de modifier BETTER_AUTH_SECRET (déconnecte tous les utilisateurs). Ajoute --force-secret si tu es sûr." ;;
      DB_URI=*)
        warn "DB_URI est normalement dérivé au runtime depuis SCALINGO_POSTGRESQL_URL ; il ne prime que pour une instance SANS addon PG (DB externe/tunnel)." ;;
    esac
  done

  sc env-set "${pairs[@]}"
  ok "Variables posées. Scalingo redémarre l'app automatiquement."
}

cmd_set_key() {
  resolve_app "${1:-}"
  local -a keys=()
  [ -n "${ANTHROPIC_API_KEY:-}" ] && keys+=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  [ -n "${MISTRAL_API_KEY:-}" ]   && keys+=("MISTRAL_API_KEY=$MISTRAL_API_KEY")
  [ -n "${OPENAI_API_KEY:-}" ]    && keys+=("OPENAI_API_KEY=$OPENAI_API_KEY")
  [ "${#keys[@]}" -gt 0 ] || die "aucune clé en env (ANTHROPIC_API_KEY / MISTRAL_API_KEY / OPENAI_API_KEY)"
  sc env-set "${keys[@]}"
  ok "Clé(s) LLM posée(s)."
}

cmd_list() {
  scalingo --region "$REGION" apps | grep -E 'nao-' || info "aucune app nao-* dans $REGION"
}

cmd_env()         { resolve_app "${1:-}"; sc env; }
cmd_logs()        { resolve_app "${1:-}"; sc logs -f; }
cmd_restart()     { resolve_app "${1:-}"; sc restart; }
cmd_status()      { resolve_app "${1:-}"; sc ps; }
cmd_open()        { resolve_app "${1:-}"; sc open; }
cmd_cache_clear() { resolve_app "${1:-}"; sc deployment-cache-delete; info "Cache vidé — relance : ./$SCRIPT_NAME deploy $PRODUCT"; }

cmd_scale() {
  resolve_app "${1:-}"
  local size="${2:-}"
  [ -n "$size" ] || usage_error "taille requise (S|M|L|XL|2XL)"
  case "$size" in S|M|L|XL|2XL) ;; *) die "taille invalide : $size (S|M|L|XL|2XL)" ;; esac
  sc scale "web:1:$size"
}

cmd_run() {
  resolve_app "${1:-}"; shift || true
  [ "$#" -gt 0 ] || usage_error "commande requise : run <produit> <cmd...>"
  sc run "$@"
}

cmd_destroy() {
  local product=""
  for a in "$@"; do
    case "$a" in
      --yes|-y) ASSUME_YES=1 ;;
      *)        product="$a" ;;
    esac
  done
  resolve_app "$product"
  warn "Cela DÉTRUIT l'app $APP, sa base PostgreSQL et toutes ses données. IRRÉVERSIBLE."
  if [ "$ASSUME_YES" != 1 ]; then
    local ans
    read -r -p "Tape le nom du produit ($PRODUCT) pour confirmer : " ans
    [ "$ans" = "$PRODUCT" ] || die "abandon (saisie ≠ $PRODUCT)"
  fi
  sc destroy --force
  ok "$APP détruite."
}

# =====================================================================================
# Blocs partagés (cœur de la séparation create / deploy)
# =====================================================================================

# Provisionne l'app + l'addon PostgreSQL (create only, idempotent).
provision() {
  step "Création de l'app $APP ($REGION)"
  scalingo --region "$REGION" create "$APP" || info "app déjà créée, on continue"

  if [ "$NO_PG" = 1 ] || [ -n "${DB_URI:-}" ] || env_has DB_URI; then
    info "Addon PostgreSQL ignoré (--no-pg ou DB_URI fourni : DB externe / tunnel)."
  else
    step "Addon PostgreSQL ($PG_PLAN)"
    sc addons-add postgresql "$PG_PLAN" || info "addon déjà présent, on continue"
  fi
}

# Construit ENV_ARGS (create only). Reprend les valeurs inline, sinon celles déjà sur l'app.
# DB_URI n'est PAS posé par défaut : bin/web.sh le dérive de SCALINGO_POSTGRESQL_URL.
build_create_env() {
  local ctx_url ctx_branch
  ctx_url="$(resolve_value NAO_CONTEXT_GIT_URL required)"
  ctx_branch="$(resolve_value NAO_CONTEXT_GIT_BRANCH)"; ctx_branch="${ctx_branch:-main}"

  ENV_ARGS=(
    MODE=prod
    NODE_ENV=production
    HUSKY=0
    FASTAPI_PORT=8005
    NAO_CONTEXT_SOURCE=git
    "NAO_CONTEXT_GIT_URL=$ctx_url"
    "NAO_CONTEXT_GIT_BRANCH=$ctx_branch"
    "BETTER_AUTH_URL=https://${APP}.${REGION}.scalingo.io"
  )

  # BETTER_AUTH_SECRET : généré une seule fois ; jamais re-posé s'il existe (anti-rotation).
  if env_has BETTER_AUTH_SECRET; then
    info "BETTER_AUTH_SECRET déjà défini — conservé (pas de rotation)."
  else
    ENV_ARGS+=("BETTER_AUTH_SECRET=$(openssl rand -hex 32)")
    info "BETTER_AUTH_SECRET généré."
  fi

  # Optionnels : posés uniquement si fournis inline (sinon on garde ce qui est sur l'app).
  [ -n "${DB_URI:-}" ]                  && ENV_ARGS+=("DB_URI=$DB_URI")
  [ -n "${NAO_CONTEXT_GIT_SUBPATH:-}" ] && ENV_ARGS+=("NAO_CONTEXT_GIT_SUBPATH=$NAO_CONTEXT_GIT_SUBPATH")
  [ -n "${NAO_CONTEXT_GIT_TOKEN:-}" ]   && ENV_ARGS+=("NAO_CONTEXT_GIT_TOKEN=$NAO_CONTEXT_GIT_TOKEN")
  [ -n "${ANTHROPIC_API_KEY:-}" ]       && ENV_ARGS+=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  [ -n "${MISTRAL_API_KEY:-}" ]         && ENV_ARGS+=("MISTRAL_API_KEY=$MISTRAL_API_KEY")
  [ -n "${OPENAI_API_KEY:-}" ]          && ENV_ARGS+=("OPENAI_API_KEY=$OPENAI_API_KEY")

  # La dernière ligne `[ -n ... ] && ...` peut renvoyer 1 (test faux) ; sous set -e
  # cela ferait sortir le script à l'appel nu de la fonction. On force un retour 0.
  return 0
}

# Archive le HEAD (+ overlay instance) et déploie. SEULE action de deploy/update.
# Overlay : instances/<produit>/ écrase la base (Procfile, Aptfile, .buildpacks, bin/…).
# Le dossier racine unique dans l'archive est OBLIGATOIRE (sinon .buildpacks ignoré → build
# python-only). Cf. doc.scalingo.com/platform/deployment/deploy-from-archive.
deploy_archive() {
  require_clean_head
  local sha appdir
  sha="$(git rev-parse --short HEAD)"
  # Variables globales nettoyées par cleanup() (trap EXIT) — pas de trap RETURN sur des locales.
  DEPLOY_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${APP}.XXXXXX")"
  DEPLOY_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/${APP}-${sha}.XXXXXX")"
  DEPLOY_ARCHIVE="${DEPLOY_ARCHIVE}.tar.gz"

  appdir="$DEPLOY_TMP_ROOT/$APP"
  mkdir -p "$appdir"
  git archive HEAD | tar -x -C "$appdir"

  if [ -d "$REPO_ROOT/instances/$PRODUCT" ]; then
    info "Overlay instances/$PRODUCT/ appliqué."
    cp -a "$REPO_ROOT/instances/$PRODUCT/." "$appdir/"
  fi

  step "Déploiement de $APP (HEAD=$sha)"
  tar -czf "$DEPLOY_ARCHIVE" -C "$DEPLOY_TMP_ROOT" "$APP"
  sc deploy "$DEPLOY_ARCHIVE" "$sha"
  ok "Déployé : https://${APP}.${REGION}.scalingo.io"
}

# git archive ne capture que le COMMIT : avertir si des changements ne sont pas commités.
require_clean_head() {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "pas dans un dépôt git : $REPO_ROOT"
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    warn "Des changements non commités ne seront PAS déployés (git archive = dernier commit)."
    confirm "Continuer avec le dernier commit ?" || die "abandon"
  fi
}

# =====================================================================================
# Helpers bas-niveau
# =====================================================================================
sc() { scalingo --region "$REGION" --app "$APP" "$@"; }

resolve_app() {
  PRODUCT="${1:-}"
  [ -n "$PRODUCT" ] || usage_error "produit manquant"
  APP="nao-$PRODUCT"
  APP_ENV_LOADED=0   # invalide le cache d'env entre deux apps
}

require_scalingo() {
  command -v scalingo >/dev/null 2>&1 || die "CLI scalingo introuvable — https://cli.scalingo.com"
  scalingo --region "$REGION" whoami >/dev/null 2>&1 || die "non authentifié — lance : scalingo login"
}

# Charge l'env de l'app une seule fois (tolère une app inexistante → env vide).
load_app_env() {
  APP_ENV="$(sc env 2>/dev/null || true)"
  APP_ENV_LOADED=1
}

env_has() {  # KEY
  [ "$APP_ENV_LOADED" = 1 ] || load_app_env
  printf '%s\n' "$APP_ENV" | grep -q "^$1="
}

env_get() {  # KEY → valeur (vide si absente)
  [ "$APP_ENV_LOADED" = 1 ] || load_app_env
  printf '%s\n' "$APP_ENV" | grep "^$1=" | head -1 | cut -d= -f2-
}

# Valeur d'une variable : inline (env) → existante sur l'app → erreur si 'required'.
resolve_value() {  # VAR_NAME [required]
  local name="$1" required="${2:-}" inline existing
  inline="${!name:-}"
  if [ -n "$inline" ]; then printf '%s' "$inline"; return; fi
  existing="$(env_get "$name")"
  if [ -n "$existing" ]; then printf '%s' "$existing"; return; fi
  [ -z "$required" ] || die "$name requis (ni en env inline, ni déjà posé sur l'app $APP)"
}

confirm() {  # prompt
  [ "$ASSUME_YES" = 1 ] && return 0
  local ans
  read -r -p "$(printf '%s [y/N] ' "$1")" ans
  case "$ans" in [yYoO]*) return 0 ;; *) return 1 ;; esac
}

info()  { printf '%sℹ%s %s\n'  "$C_INFO" "$C_RESET" "$*" >&2; }
ok()    { printf '%s✓%s %s\n'  "$C_OK"   "$C_RESET" "$*" >&2; }
warn()  { printf '%s⚠%s %s\n'  "$C_WARN" "$C_RESET" "$*" >&2; }
err()   { printf '%s✗%s %s\n'  "$C_ERR"  "$C_RESET" "$*" >&2; }
step()  { printf '\n%s=== %s ===%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }
die()   { err "$*"; exit 1; }
usage_error() { err "$*"; echo >&2; usage; exit 2; }

main "$@"
