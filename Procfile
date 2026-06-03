# release : joue les migrations Drizzle avant la mise en ligne (gating du déploiement).
#           NB : `serve` re-joue aussi les migrations au boot, c'est idempotent.
# web     : lance le sidecar FastAPI (uvicorn, port interne) + le backend bun sur $PORT.
release: bash bin/release.sh
web: bash bin/web.sh
