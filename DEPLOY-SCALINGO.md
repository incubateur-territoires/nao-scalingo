# Déployer nao sur Scalingo (1 instance par produit)

Méthode de déploiement de [nao](https://getnao.io) sur **Scalingo** via **buildpacks**
(Scalingo ne déploie pas d'image Docker). Chaque produit a **sa propre instance** : une app,
une base PostgreSQL, un repo de contexte et une clé LLM dédiés → **données isolées**.

## Architecture

nao est un monorepo polyglotte. Sur Scalingo on reproduit le build Docker amont avec un
**multi-buildpack** et on lance **deux process dans le conteneur `web`** :

- **backend** (Bun) : `bun run apps/backend/src/cli.ts serve --port $PORT` — sert aussi le frontend (build Vite) en statique.
- **sidecar FastAPI** (Python/uvicorn) sur `127.0.0.1:8005` — le backend l'appelle en `localhost` (codé en dur amont).

Les deux sont co-localisés (pas de réseau privé) car le backend appelle FastAPI en `localhost` ; les
séparer imposerait de patcher le code amont (`execute-sql.ts`, `live-story.ts`).

## Fichiers de cet overlay

| Fichier | Rôle |
|---|---|
| `.buildpacks` | apt → python → bun (le dernier fixe le start) |
| `Aptfile` | paquets système (git, chromium, libpq, openssh, deps build Python) |
| `.python-version` | Python 3.12 |
| `requirements.txt` | `uv` (déclenche la détection du python-buildpack) |
| `.slugignore` | allège le slug (<2 GiB) |
| `Procfile` | `release` (migrations) + `web` (sidecar + backend) |
| `bin/build.sh` | hook `heroku-postbuild` → build Python + JS |
| `bin/build-python.sh` | `uv pip install '.[all]'` (FastAPI, ibis, providers LLM dont mistral) |
| `bin/build-js.sh` | `bun install` + `vite build` du frontend |
| `bin/web.sh` | clone du contexte git + sidecar + backend sur `$PORT` |
| `bin/release.sh` | migrations Drizzle (gating déploiement) |
| `scalingo.json` | manifeste addons + env (review apps / one-click) |
| `new-instance.sh` | provisionne + déploie une instance produit |
| `package.json` | ajout du script `heroku-postbuild` (seule modif d'un fichier amont) |

## Pré-requis

1. **CLI Scalingo** installée et authentifiée : `scalingo login`.
2. **Accès région `osc-secnum-fr1`** (SecNumCloud) activé par le support Scalingo (entité EU requise).
3. Le repo de déploiement (ce fork) poussé sur GitHub (`incubateur-territoires/nao-scalingo`).

## Créer une nouvelle instance

```bash
NAO_CONTEXT_GIT_URL=https://github.com/incubateur-territoires/contexte-<produit>.git \
ANTHROPIC_API_KEY=sk-ant-... \
./new-instance.sh <produit>
```

Cela crée l'app `nao-<produit>`, l'addon PostgreSQL, les variables d'env, puis déploie la branche courante.

Variables reconnues : `NAO_CONTEXT_GIT_URL` (requis), `ANTHROPIC_API_KEY`/`MISTRAL_API_KEY`/`OPENAI_API_KEY`,
`NAO_CONTEXT_GIT_BRANCH`, `NAO_CONTEXT_GIT_SUBPATH`, `NAO_CONTEXT_GIT_TOKEN` (repo privé),
`SCALINGO_REGION` (déf. `osc-secnum-fr1`), `PG_PLAN`, `WEB_SIZE`.

## Variables d'environnement clés

- `DB_URI` : **non défini manuellement** — `bin/web.sh` le dérive de `SCALINGO_POSTGRESQL_URL` (auto-roté).
- `BETTER_AUTH_SECRET` : secret de session, **stable** (sinon déconnexions au restart).
- `BETTER_AUTH_URL` : URL publique de l'app.
- LLM : `ANTHROPIC_API_KEY` (test initial) ou `MISTRAL_API_KEY` (Mistral est supporté nativement, cf. `cli/.[all]`).
  Le provider effectif se choisit dans le `nao_config.yaml` du repo de contexte.

## Maintenance / suivi upstream

Tous les ajouts sont des **fichiers neufs** ; seule modif amont = le script `heroku-postbuild` dans
`package.json`. La synchro se fait via le bouton **« Sync fork »** de GitHub sur `main`. En cas de conflit,
il ne portera que sur `package.json` (trivial à résoudre).

## À surveiller au premier déploiement

- **Taille du slug** (limite 2 GiB) : chromium + node_modules + site-packages Python. Si dépassement,
  retirer `chromium`/`chromium-driver` de l'`Aptfile` (à valider selon les fonctions utilisées).
- **Buildpack Bun** (`jakeg/heroku-buildpack-bun`, communautaire) : vérifier qu'il joue bien
  `heroku-postbuild` et fournit `bun` au runtime. Au besoin épingler un commit (`URL#<sha>`) ou tester `confact/bun-buildpack`.
- **Install Python via uv** : confirmer que `apps.backend.fastapi.main:app` s'importe au runtime
  (paquets dans le bon interpréteur). Voir `scalingo --app <app> run python -c "import fastapi"`.
- **Boxlite/KVM** : `@boxlite-ai/boxlite` attend `/dev/kvm` (absent) ; validé que l'exécution SQL passe par le sidecar FastAPI.
- **`vite build` sous Bun** : si un plugin exige le binaire `node`, ajouter `Scalingo/nodejs-buildpack.git`
  **avant** bun dans `.buildpacks`.
