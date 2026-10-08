#!/usr/bin/env bash
#
# Gestion des instances nao sur Scalingo (création, déploiement, exploitation).
# Une instance = app "nao-<produit>" + PostgreSQL + repo de contexte + clé LLM (données isolées).
#
# Deux accès à Scalingo, choisis automatiquement :
#   - CLI  : `scalingo` authentifié (`scalingo login`), droits complets du compte. Mode humain.
#   - FGP  : API REST derrière le proxy fine-grained (fgp.incubateur.net), restreinte aux apps
#            nao-*. Activé dès que FGP_BLOB est défini (typiquement via .env.fgp). Mode agent.
# Cf. DEPLOY-SCALINGO.md § « Accès restreint via FGP ».
#
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
FGP_URL="${FGP_URL:-https://fgp.incubateur.net}"
POSTGRESQL_PROVIDER="postgresql"

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
API_ERROR=""
API_STATUS=""
APP_ENV_READABLE=0

# Temporaires, nettoyés par cleanup() (trap EXIT).
DEPLOY_TMP_ROOT=""
DEPLOY_ARCHIVE=""
API_BODY_FILE=""
cleanup() {
  [ -n "${DEPLOY_TMP_ROOT:-}" ] && rm -rf "$DEPLOY_TMP_ROOT"
  [ -n "${DEPLOY_ARCHIVE:-}" ]  && rm -f  "$DEPLOY_ARCHIVE"
  [ -n "${API_BODY_FILE:-}" ]   && rm -f  "$API_BODY_FILE"
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
  load_fgp_credentials
  require_backend
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
    check)          cmd_check "$@" ;;
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
  list                          Liste les apps nao-* de la région.              [CLI seulement]
  env     <produit>             Affiche les variables d'env.
  logs    <produit> [n]         Logs : suivi continu en CLI, n dernières lignes en FGP (déf. 100).
  restart <produit>             Redémarre l'app.
  status  <produit>             État des conteneurs (alias : ps).
  scale   <produit> <taille>    Redimensionne le web (S|M|L|XL|2XL).
  run     <produit> <cmd...>    Commande one-off : interactive en CLI, détachée en FGP.
  open    <produit>             Ouvre l'URL de l'app (l'affiche en mode FGP).
  cache-clear <produit>         Vide le cache de build (si Scalingo bloque sur python-only).
  destroy <produit> [--yes]     DÉTRUIT l'app + base (confirmation).            [CLI seulement]
  check   <produit>             Vérifie l'accès Scalingo et, en FGP, l'étanchéité du blob.
  help                          Cette aide.

${C_BOLD}VARIABLES D'ENV (création)${C_RESET}
  NAO_CONTEXT_GIT_URL    (requis)  repo de contexte du produit
  ANTHROPIC_API_KEY | MISTRAL_API_KEY | OPENAI_API_KEY  (opt.) clé LLM
  NAO_CONTEXT_GIT_BRANCH (def. main)   NAO_CONTEXT_GIT_SUBPATH   NAO_CONTEXT_GIT_TOKEN
  DB_URI                 (opt.)    DB externe (implique --no-pg)
  SCALINGO_REGION (def. $REGION)   PG_PLAN (def. $PG_PLAN)   WEB_SIZE (def. $WEB_SIZE)

${C_BOLD}ACCÈS RESTREINT (FGP)${C_RESET}
  FGP_KEY + FGP_BLOB (lus dans .env.fgp s'il existe) basculent le script sur l'API REST
  derrière fgp.incubateur.net, limitée aux apps nao-*. Voir DEPLOY-SCALINGO.md.

${C_BOLD}CUSTOMISATION PAR INSTANCE${C_RESET}
  Dépose des fichiers dans instances/<produit>/ : ils écrasent la base au déploiement
  (ex. instances/<produit>/Procfile pour un tunnel SSH). Code commité, pas de secrets dedans.

${C_BOLD}EXEMPLES${C_RESET}
  NAO_CONTEXT_GIT_URL=https://github.com/.../contexte-foo.git ANTHROPIC_API_KEY=sk-ant-... \\
    ./$SCRIPT_NAME create foo
  ./$SCRIPT_NAME deploy foo
  ./$SCRIPT_NAME set-key foo            # après ANTHROPIC_API_KEY=... en env
  ./$SCRIPT_NAME logs foo 200
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
  app_env_set "${ENV_ARGS[@]}"
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

  app_env_set "${pairs[@]}"
  restart_after_env_change
}

cmd_set_key() {
  resolve_app "${1:-}"
  local -a keys=()
  [ -n "${ANTHROPIC_API_KEY:-}" ] && keys+=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  [ -n "${MISTRAL_API_KEY:-}" ]   && keys+=("MISTRAL_API_KEY=$MISTRAL_API_KEY")
  [ -n "${OPENAI_API_KEY:-}" ]    && keys+=("OPENAI_API_KEY=$OPENAI_API_KEY")
  [ "${#keys[@]}" -gt 0 ] || die "aucune clé en env (ANTHROPIC_API_KEY / MISTRAL_API_KEY / OPENAI_API_KEY)"
  app_env_set "${keys[@]}"
  info "Clé(s) LLM posée(s)."
  restart_after_env_change
}

# La CLI redémarre l'app après env-set, le PUT de l'API non (documenté côté Scalingo) : sans
# ce redémarrage explicite, la nouvelle valeur ne serait pas lue par l'app en mode FGP.
restart_after_env_change() {
  if use_fgp; then
    app_restart
    ok "Variables posées et app redémarrée."
  else
    ok "Variables posées. La CLI scalingo a déclenché le redémarrage."
  fi
}

cmd_list() {
  ! use_fgp || die "list liste toutes les apps du compte : hors périmètre du blob FGP, réservé au CLI."
  scalingo --region "$REGION" apps | grep -E 'nao-' || info "aucune app nao-* dans $REGION"
}

cmd_env()         { resolve_app "${1:-}"; app_env_lines; }
cmd_restart()     { resolve_app "${1:-}"; app_restart; ok "$APP redémarrée."; }
cmd_status()      { resolve_app "${1:-}"; app_containers; }
cmd_cache_clear() { resolve_app "${1:-}"; app_cache_clear; info "Cache vidé — relance : ./$SCRIPT_NAME deploy $PRODUCT"; }

cmd_logs() {
  resolve_app "${1:-}"
  local lines="${2:-100}"
  case "$lines" in ''|*[!0-9]*) usage_error "nombre de lignes invalide : $lines" ;; esac
  app_logs "$lines"
}

cmd_open() {
  resolve_app "${1:-}"
  if use_fgp; then
    printf 'https://%s.%s.scalingo.io\n' "$APP" "$REGION"
  else
    sc open
  fi
}

cmd_scale() {
  resolve_app "${1:-}"
  local size="${2:-}"
  [ -n "$size" ] || usage_error "taille requise (S|M|L|XL|2XL)"
  case "$size" in S|M|L|XL|2XL) ;; *) die "taille invalide : $size (S|M|L|XL|2XL)" ;; esac
  app_scale "$size"
  ok "web redimensionné en $size."
}

cmd_run() {
  resolve_app "${1:-}"; shift || true
  [ "$#" -gt 0 ] || usage_error "commande requise : run <produit> <cmd...>"
  app_run "$@"
}

cmd_destroy() {
  ! use_fgp || die "destroy est irréversible : hors périmètre du blob FGP, réservé au CLI."
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

# Recette de l'accès : l'app visée répond, et le blob refuse ce qu'il doit refuser. Rejouable
# après chaque rotation de blob — c'est là que se vérifie un scope élargi par erreur.
cmd_check() {
  resolve_app "${1:-}"
  if ! use_fgp; then
    ok "Mode CLI — compte : $(scalingo --region "$REGION" whoami 2>/dev/null || echo inconnu)"
    return 0
  fi

  info "Mode FGP — proxy $FGP_URL, région $REGION."
  api GET "/v1/apps/$APP/containers" |
    jq -r --arg app "$APP" '"✓ \($app) : \(.containers | length) type(s) de conteneur lus"'

  check_refused GET    "/v1/apps"                     "la liste des apps du compte"
  check_refused GET    "/v1/apps/$APP"                "l'app elle-même (donc /collaborators, /events, /log_drains)"
  check_refused DELETE "/v1/apps/nao-controle-de-blob" "la suppression d'une app nao-*"
}

# Un refus ne prouve l'étanchéité que s'il vient des scopes : un blob expiré refuserait tout.
check_refused() {  # MÉTHODE CHEMIN LIBELLÉ
  if api_call "$1" "$2" >/dev/null 2>&1; then
    warn "$3 : ACCESSIBLE — le blob est plus large que prévu, régénère-le depuis fgp-scopes.json."
  elif [ "$API_STATUS" = 403 ]; then
    ok "$3 : refusé par le proxy (403)."
  else
    warn "$3 : refus non concluant (${API_ERROR:-sans détail}) — à rejouer."
  fi
}

# =====================================================================================
# Blocs partagés (cœur de la séparation create / deploy)
# =====================================================================================

# Provisionne l'app + l'addon PostgreSQL (create only, idempotent).
provision() {
  step "Création de l'app $APP ($REGION)"
  if ! app_create; then
    already_exists_error || die "création de $APP impossible : $API_ERROR"
    info "app déjà créée, on continue"
  fi

  if [ "$NO_PG" = 1 ] || [ -n "${DB_URI:-}" ] || env_has DB_URI; then
    info "Addon PostgreSQL ignoré (--no-pg ou DB_URI fourni : DB externe / tunnel)."
  else
    step "Addon PostgreSQL ($PG_PLAN)"
    if ! app_addon_add "$PG_PLAN"; then
      already_exists_error || die "addon PostgreSQL impossible : $API_ERROR"
      info "addon déjà présent, on continue"
    fi
  fi

  # Taille posée AVANT le 1er déploiement : en M (défaut Scalingo), backend bun + workers uvicorn
  # dépassent la mémoire et le conteneur est tué au boot (crashed-error).
  step "Taille du conteneur web ($WEB_SIZE)"
  app_scale "$WEB_SIZE"
}

# Une ressource déjà présente remonte en 409/422 ; toute autre erreur doit arrêter create,
# sinon la suite s'enchaîne sur une app inexistante et annonce « instance prête ».
already_exists_error() {
  use_fgp || return 0   # en CLI, le message d'erreur est déjà affiché par la commande
  case "$API_STATUS" in 409|422) return 0 ;; *) return 1 ;; esac
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
  # Un env illisible n'est PAS un env vide : générer dans ce cas déconnecterait tout le monde.
  if env_has BETTER_AUTH_SECRET; then
    info "BETTER_AUTH_SECRET déjà défini — conservé (pas de rotation)."
  else
    [ "$APP_ENV_READABLE" = 1 ] || die "env de $APP illisible, refus de générer BETTER_AUTH_SECRET (une rotation déconnecterait tous les utilisateurs) : ${API_ERROR:-cause inconnue}"
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
  app_deploy "$DEPLOY_ARCHIVE" "$sha"
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
# Opérations sur une app : une implémentation CLI, une implémentation FGP
# =====================================================================================
app_env_lines() {  # → KEY=VALUE, une par ligne
  if use_fgp; then
    api GET "/v1/apps/$APP/variables" | jq -r '.variables[] | "\(.name)=\(.value)"'
  else
    sc env
  fi
}

app_env_set() {  # KEY=VALUE...
  if use_fgp; then
    api PUT "/v1/apps/$APP/variables" "$(variables_payload "$@")" >/dev/null
  else
    sc env-set "$@"
  fi
}

# parent_id vide et explicite : le blob FGP l'exige, sinon l'app pourrait naître enfant d'une
# app hors périmètre et en hériter la configuration (cf. DEPLOY-SCALINGO.md).
app_create() {
  if use_fgp; then
    api_call POST "/v1/apps" "$(jq -n --arg name "$APP" '{app: {name: $name, parent_id: ""}}')" >/dev/null
  else
    scalingo --region "$REGION" create "$APP"
  fi
}

app_addon_add() {  # PLAN
  local plan="$1" plan_id
  if use_fgp; then
    plan_id="$(postgresql_plan_id "$plan")"
    [ -n "$plan_id" ] || { API_ERROR="plan PostgreSQL inconnu : $plan"; return 1; }
    api_call POST "/v1/apps/$APP/addons" \
      "$(jq -n --arg provider "$POSTGRESQL_PROVIDER" --arg plan "$plan_id" \
            '{addon: {addon_provider_id: $provider, plan_id: $plan}}')" >/dev/null
  else
    sc addons-add "$POSTGRESQL_PROVIDER" "$plan"
  fi
}

app_deploy() {  # ARCHIVE SHA
  local archive="$1" sha="$2" source upload_url download_url deployment_id upload_status
  if ! use_fgp; then
    sc deploy "$archive" "$sha"
    return
  fi

  source="$(api POST "/v1/sources")"
  upload_url="$(jq -r '.source.upload_url // empty' <<<"$source")"
  download_url="$(jq -r '.source.download_url // empty' <<<"$source")"
  [ -n "$upload_url" ] && [ -n "$download_url" ] \
    || die "POST /v1/sources : réponse sans URL d'envoi exploitable"

  # URL pré-signée : elle porte sa propre autorisation, donc elle ne passe pas par le proxy.
  # --location et le Content-Type suivent l'exemple Scalingo ; le code HTTP est vérifié à la
  # main parce que --fail ignore une redirection, qui sortirait en 0 sans rien avoir envoyé.
  upload_status="$(curl --silent --show-error --location --output /dev/null \
      --write-out '%{http_code}' --header 'Content-Type: application/x-gzip' \
      --upload-file "$archive" "$upload_url")" \
    || die "envoi de l'archive : curl a échoué"
  case "$upload_status" in
    2??) ;;
    *) die "envoi de l'archive refusé par le stockage Scalingo (HTTP $upload_status)" ;;
  esac

  deployment_id="$(api POST "/v1/apps/$APP/deployments" \
    "$(jq -n --arg ref "$sha" --arg url "$download_url" \
          '{deployment: {git_ref: $ref, source_url: $url}}')" | jq -r '.deployment.id // empty')"
  [ -n "$deployment_id" ] || die "déploiement créé mais sans identifiant exploitable"
  watch_deployment "$deployment_id"
}

app_restart() {
  if use_fgp; then
    api POST "/v1/apps/$APP/restart" '{}' >/dev/null
  else
    sc restart
  fi
}

app_scale() {  # TAILLE
  local size="$1"
  if use_fgp; then
    api POST "/v1/apps/$APP/scale" \
      "$(jq -n --arg size "$size" '{containers: [{name: "web", amount: 1, size: $size}]}')" >/dev/null
  else
    sc scale "web:1:$size"
  fi
}

# L'endpoint renvoie les types de conteneurs (nom, nombre, taille), pas les instances en cours.
app_containers() {
  if use_fgp; then
    api GET "/v1/apps/$APP/containers" |
      jq -r '.containers[] | "\(.name)\t\(.amount)\t\(.size)\t\(.command // "")"'
  else
    sc ps
  fi
}

app_cache_clear() {
  if use_fgp; then
    api DELETE "/v1/apps/$APP/caches/deployment" >/dev/null
  else
    sc deployment-cache-delete
  fi
}

# Le suivi continu passe par une websocket que curl ne sait pas tenir : en mode FGP on lit
# les n dernières lignes via l'URL signée renvoyée par l'API (hôte logs.<région>.scalingo.com).
app_logs() {  # NB_LIGNES
  local lines="$1" logs_url separator='&'
  if ! use_fgp; then
    sc logs -f
    return
  fi
  logs_url="$(api GET "/v1/apps/$APP/logs" | jq -r '.logs_url')"
  case "$logs_url" in *\?*) ;; *) separator='?' ;; esac
  curl --silent --show-error --fail "${logs_url}${separator}n=${lines}" \
    || die "lecture des logs refusée (URL signée expirée ?)"
}

# En mode FGP la commande part en détaché : l'attachement interactif utilise un protocole
# propre au CLI. La sortie se retrouve dans les logs de l'app.
app_run() {  # CMD...
  if ! use_fgp; then
    sc run "$@"
    return
  fi
  api POST "/v1/apps/$APP/run" \
    "$(jq -n --arg cmd "$*" '{command: $cmd, detached: true}')" |
    jq -r '"conteneur one-off \(.container.label // .container.id) lancé (détaché)"'
  info "Sortie : ./$SCRIPT_NAME logs $PRODUCT"
}

# Suit un déploiement jusqu'à son état final. Une lecture de statut qui échoue n'est pas un
# déploiement qui échoue : il continue côté Scalingo, donc on retente avant d'abandonner. Un
# statut vide est traité comme « en cours » : l'absence du champ ne vaut pas échec.
watch_deployment() {  # ID
  local id="$1" status="" previous="" response failures=0 waited=0
  local max_failures=5 max_wait=3600
  while [ "$waited" -lt "$max_wait" ]; do
    if ! response="$(api_call GET "/v1/apps/$APP/deployments/$id")"; then
      failures=$((failures + 1))
      [ "$failures" -lt "$max_failures" ] \
        || die "suivi abandonné après $max_failures lectures en échec (le déploiement continue côté Scalingo) : $API_ERROR"
      warn "statut illisible ($failures/$max_failures), nouvelle tentative : $API_ERROR"
      sleep 5; waited=$((waited + 5)); continue
    fi
    failures=0
    status="$(jq -r '.deployment.status // empty' <<<"$response" 2>/dev/null || true)"
    [ -z "$status" ] || [ "$status" = "$previous" ] || info "déploiement : $status"
    previous="$status"
    case "$status" in
      success) return 0 ;;
      ''|queued|building|pushing|starting) sleep 5; waited=$((waited + 5)) ;;
      *)
        err "déploiement en échec ($status) — fin du log :"
        deployment_output "$id" | tail -40 >&2
        exit 1 ;;
    esac
  done
  die "déploiement toujours en cours après $((max_wait / 60)) min — dernier statut : ${status:-inconnu}"
}

# La sortie arrive en texte brut ou enveloppée dans du JSON selon la négociation de contenu.
deployment_output() {  # ID
  local raw text
  raw="$(api_call GET "/v1/apps/$APP/deployments/$1/output" || true)"
  text="$(jq -r '.deployment.output // .output // empty' <<<"$raw" 2>/dev/null || true)"
  printf '%s\n' "${text:-$raw}"
}

# Les paires passent en arguments jq, jamais par un pipeline ligne à ligne : une valeur
# multiligne (clé PEM, JSON de service) y serait tronquée et sa 2e ligne prise pour une
# variable de plus.
variables_payload() {  # KEY=VALUE... → {"variables":[{"name":…,"value":…}]}
  jq -n '{variables: [$ARGS.positional[]
          | split("=")
          | {name: .[0], value: (.[1:] | join("="))}]}' --args "$@"
}

# Vide si le plan est introuvable : l'appelant décide, un die ici ne quitterait que la
# substitution de commande et laisserait partir un plan_id vide.
postgresql_plan_id() {  # NOM_DU_PLAN → identifiant du plan, vide si inconnu
  api_call GET "/v1/addon_providers/$POSTGRESQL_PROVIDER/plans" 2>/dev/null |
    jq -r --arg plan "$1" '.plans[] | select(.name == $plan) | .id' 2>/dev/null || true
}

# =====================================================================================
# Accès bas niveau : CLI scalingo ou API REST derrière FGP
# =====================================================================================
use_fgp() { [ -n "${FGP_BLOB:-}" ]; }

sc() { scalingo --region "$REGION" --app "$APP" "$@"; }

# Appel API via le proxy. Sort du script sur erreur (cas majoritaire).
api() {
  api_call "$@" || die "$API_ERROR"
}

# Variante tolérante : renseigne API_ERROR / API_STATUS et renvoie 1 au lieu de sortir.
# Clé, blob et corps passent par un fichier de configuration curl et un fichier temporaire,
# jamais par la ligne de commande : `ps` les exposerait à tout utilisateur local.
api_call() {  # MÉTHODE CHEMIN [CORPS_JSON]
  local method="$1" path="$2" payload="${3:-}" response status body
  local -a args=(--silent --show-error --write-out $'\n%{http_code}' --request "$method" --config -)
  if [ -n "$payload" ]; then
    [ -n "$API_BODY_FILE" ] || { API_BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/fgp-body.XXXXXX")"; chmod 600 "$API_BODY_FILE"; }
    printf '%s' "$payload" > "$API_BODY_FILE"
    args+=(--header 'Content-Type: application/json' --data "@$API_BODY_FILE")
  fi

  API_ERROR=""; API_STATUS=""
  if ! response="$(fgp_curl_config | curl "${args[@]}" "$FGP_URL$path")"; then
    API_ERROR="proxy FGP injoignable ($method $path)"
    return 1
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  API_STATUS="$status"
  if [ "$status" -ge 400 ]; then
    API_ERROR="$(api_error_message "$method" "$path" "$status" "$body")"
    return 1
  fi
  printf '%s' "$body"
}

fgp_curl_config() {
  printf 'header = "X-FGP-Key: %s"\nheader = "X-FGP-Blob: %s"\n' "${FGP_KEY:-}" "${FGP_BLOB:-}"
}

# Les erreurs du proxy (X-FGP-Source: proxy) portent un code dans le corps JSON ; tout le
# reste vient de Scalingo et remonte tel quel.
api_error_message() {  # MÉTHODE CHEMIN STATUT CORPS
  local method="$1" path="$2" status="$3" body="$4" code
  code="$(jq -r '.error // empty' <<<"$body" 2>/dev/null || true)"
  case "$code" in
    scope_denied)
      printf '%s %s hors des scopes du blob FGP (HTTP 403).' "$method" "$path" ;;
    token_expired)
      printf 'blob FGP expiré : régénère-le (DEPLOY-SCALINGO.md § Accès restreint via FGP).' ;;
    missing_key|invalid_credentials)
      printf 'FGP_KEY absente ou ne correspondant pas au blob (HTTP %s).' "$status" ;;
    auth_exchange_failed|auth_addon_failed)
      printf 'le proxy n'\''a pas pu échanger le token Scalingo : token révoqué ou expiré.' ;;
    *)
      printf '%s %s → HTTP %s : %s' "$method" "$path" "$status" "$body" ;;
  esac
}

# Charge FGP_KEY / FGP_BLOB depuis .env.fgp (jamais commité) sauf s'ils sont déjà en env.
load_fgp_credentials() {
  local env_file="$REPO_ROOT/.env.fgp"
  if [ -z "${FGP_BLOB:-}" ] && [ -f "$env_file" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$env_file"
    set +a
  fi
}

require_backend() {
  if use_fgp; then
    case "$FGP_BLOB" in
      null|'null') die ".env.fgp contient FGP_BLOB=null : la génération du blob a échoué, régénère-le." ;;
    esac
    [ -n "${FGP_KEY:-}" ] || die "FGP_BLOB est défini mais pas FGP_KEY (cf. .env.fgp.example)"
    command -v curl >/dev/null 2>&1 || die "curl introuvable"
    command -v jq   >/dev/null 2>&1 || die "jq introuvable"
  else
    command -v scalingo >/dev/null 2>&1 || die "CLI scalingo introuvable — https://cli.scalingo.com"
    scalingo --region "$REGION" whoami >/dev/null 2>&1 || die "non authentifié — lance : scalingo login"
  fi
}

# =====================================================================================
# Helpers bas-niveau
# =====================================================================================
# Scalingo impose 6 à 48 caractères, minuscules alphanumériques et tirets. Valider ici évite
# un 422 opaque au milieu d'un create, et garde PRODUCT hors de toute ruse de chemin.
resolve_app() {
  PRODUCT="${1:-}"
  [ -n "$PRODUCT" ] || usage_error "produit manquant"
  case "$PRODUCT" in
    *[!a-z0-9-]*|-*|*-) usage_error "produit invalide : $PRODUCT (minuscules, chiffres et tirets, sans tiret en tête ni en fin)" ;;
  esac
  [ "${#PRODUCT}" -ge 2 ] || usage_error "produit trop court : $PRODUCT (l'app nao-<produit> doit faire 6 caractères au moins)"
  APP="nao-$PRODUCT"
  APP_ENV_LOADED=0   # invalide le cache d'env entre deux apps
}

# Charge l'env de l'app une seule fois. Distingue trois cas, parce que les confondre ferait
# régénérer BETTER_AUTH_SECRET : env lu, app inexistante (404 → env vide, c'est une
# certitude), lecture impossible (APP_ENV_READABLE reste à 0).
load_app_env() {
  APP_ENV=""; APP_ENV_READABLE=0; APP_ENV_LOADED=1
  if ! use_fgp; then
    if APP_ENV="$(sc env 2>/dev/null)"; then APP_ENV_READABLE=1; else APP_ENV=""; fi
    return 0
  fi
  # Appel direct d'abord : son code HTTP reste visible ici, contrairement à celui d'une
  # substitution de commande, qui s'exécute dans un sous-shell.
  if api_call GET "/v1/apps/$APP/variables" >/dev/null; then
    APP_ENV_READABLE=1
    APP_ENV="$(app_env_lines 2>/dev/null || true)"
  elif [ "$API_STATUS" = 404 ]; then
    APP_ENV_READABLE=1
  fi
  return 0
}

env_has() {  # KEY
  [ "$APP_ENV_LOADED" = 1 ] || load_app_env
  printf '%s\n' "$APP_ENV" | grep -q "^$1="
}

env_get() {  # KEY → valeur (vide si absente)
  [ "$APP_ENV_LOADED" = 1 ] || load_app_env
  printf '%s\n' "$APP_ENV" | grep "^$1=" | head -1 | cut -d= -f2- || true
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
