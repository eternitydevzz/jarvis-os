#!/bin/bash
# Jarvis (Mac): arranca Docker y WAHA/Whisper y luego el puente.
# Lo lanza launchd al iniciar sesión (com.jarvis.agent); KeepAlive lo reinicia si se cae.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$ROOT/logs"
LOG="$LOG_DIR/start.log"
CONSOLE="$LOG_DIR/bridge-console.log"
DOCKER_WAIT_SECONDS=180

mkdir -p "$LOG_DIR"
log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" >> "$LOG"; }

if ! docker info >/dev/null 2>&1; then
  log 'Docker apagado: arrancando Docker Desktop'
  open -a Docker 2>/dev/null
  waited=0
  until docker info >/dev/null 2>&1; do
    if [ "$waited" -ge "$DOCKER_WAIT_SECONDS" ]; then
      log 'ERROR: Docker no respondió en 3 minutos'
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
fi
log 'Docker listo'

if ! docker compose -f "$ROOT/waha/docker-compose.yml" up -d >> "$CONSOLE" 2>&1; then
  log 'ERROR: no pude levantar WAHA/Whisper'
  exit 1
fi
log 'WAHA y Whisper levantados; arrancando el puente'

exec node "$ROOT/bridge/server.mjs" >> "$CONSOLE" 2>&1
