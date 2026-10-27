#!/bin/bash
# Jarvis · instalación en Mac en un solo comando:  bash scripts/setup.sh
# Pide nombre y número, genera las claves, arranca WAHA + Whisper, enseña el QR,
# conecta el puente, lo deja siempre encendido (launchd) y manda un "hola" de prueba.
# Compatible con el bash 3.2 de macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WAHA_URL="http://127.0.0.1:3000"
SESSION="default"
LABEL="com.jarvis.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
QR_DIR="$ROOT/waha/qr"
QR_TIMEOUT_SECONDS=300

step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { printf '\n  ✗ %s\n' "$*" >&2; exit 1; }

# Lee un campo de un JSON por stdin (Node ya es requisito; así no hace falta jq).
json_get() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=process.argv[1].split(".").reduce((o,k)=>o==null?o:o[k],JSON.parse(s));console.log(v==null?"":v)}catch{console.log("")}})' "$1"; }

waha() { curl -s -H "X-Api-Key: $WAHA_API_KEY" "$@"; }

# ---------------------------------------------------------------------------
step "1/8 · Compruebo lo que necesitas"
command -v docker >/dev/null || fail "Falta Docker Desktop: https://www.docker.com/products/docker-desktop/"
command -v node >/dev/null   || fail "Falta Node 22+:  brew install node"
command -v claude >/dev/null || fail "Falta Claude Code:  brew install --cask claude-code"
command -v openssl >/dev/null || fail "Falta openssl"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 22 ] || fail "Tu Node es $NODE_MAJOR; necesitas 22 o más:  brew upgrade node"
[ "$(claude auth status 2>/dev/null | json_get loggedIn)" = "true" ] || fail "Claude Code no tiene sesión: abre 'claude', escribe /login y vuelve a ejecutar esto"
if ! docker info >/dev/null 2>&1; then
  echo "  Docker está apagado; lo abro y espero…"
  open -a Docker 2>/dev/null || true
  for _ in $(seq 1 36); do docker info >/dev/null 2>&1 && break; sleep 5; done
  docker info >/dev/null 2>&1 || fail "Docker no arrancó en 3 minutos. Ábrelo a mano y repite."
fi
[ -f "$ROOT/config.env" ] && fail "Ya hay un Jarvis configurado aquí (config.env). Para empezar de cero borra config.env, .secrets/ y waha/.sessions/."
ok "Docker, Node $NODE_MAJOR y Claude Code con sesión"

# ---------------------------------------------------------------------------
step "2/8 · Unos datos tuyos"
read -r -p "  Tu nombre: " OWNER_NAME
read -r -p "  ¿A qué te dedicas? (una línea): " OWNER_ABOUT
read -r -p "  Tu WhatsApp PERSONAL, con prefijo (ej. +34600111222): " PHONE_RAW
read -r -p "  Zona horaria [Europe/Madrid]: " TZ_IN
OWNER_PHONE="$(printf '%s' "$PHONE_RAW" | tr -cd '0-9')"
TZ_VALUE="${TZ_IN:-Europe/Madrid}"
[ -n "$OWNER_NAME" ] || fail "El nombre no puede ir vacío"
[ "${#OWNER_PHONE}" -ge 8 ] || fail "Ese número no parece válido: $PHONE_RAW"
ok "Hola $OWNER_NAME"

# ---------------------------------------------------------------------------
step "3/8 · Genero tus claves (no se muestran)"
umask 077
mkdir -p "$ROOT/.secrets"
WAHA_API_KEY="$(openssl rand -hex 32)"
WAHA_HASH="$(printf '%s' "$WAHA_API_KEY" | openssl dgst -sha512 | awk '{print $NF}')"
DASH_PW="$(openssl rand -hex 16)"
HMAC_KEY="$(openssl rand -hex 32)"
printf 'WAHA_API_KEY=sha512:%s\nWAHA_DASHBOARD_USERNAME=jarvis\nWAHA_DASHBOARD_PASSWORD=%s\nWHATSAPP_SWAGGER_USERNAME=jarvis\nWHATSAPP_SWAGGER_PASSWORD=%s\n' \
  "$WAHA_HASH" "$DASH_PW" "$DASH_PW" > "$ROOT/waha/.env"
printf 'WAHA_API_KEY=%s\nWAHA_URL=%s\n' "$WAHA_API_KEY" "$WAHA_URL" > "$ROOT/.secrets/waha.env"
printf 'WEBHOOK_HMAC_KEY=%s\n' "$HMAC_KEY" > "$ROOT/.secrets/bridge.env"
umask 022
ok "Claves guardadas en .secrets/ y waha/.env"

# ---------------------------------------------------------------------------
step "4/8 · Descargo y arranco WhatsApp (WAHA) y Whisper · la primera vez son ~2-3 GB"
docker compose -f "$ROOT/waha/docker-compose.yml" up -d
docker pull -q pandoc/core:3.11.0 >/dev/null   # conversor a Word para los contratos
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Api-Key: $WAHA_API_KEY" "$WAHA_URL/api/sessions" || true)"
  [ "$code" = "200" ] && break
  sleep 3
done
[ "$code" = "200" ] || fail "WAHA no responde. Mira: docker logs jarvis-waha"
ok "WAHA responde"

# ---------------------------------------------------------------------------
step "5/8 · Conecta tu número SECUNDARIO de WhatsApp"
WEBHOOK_JSON="{\"url\":\"http://host.docker.internal:3100/webhook\",\"events\":[\"message\"],\"hmac\":{\"key\":\"$HMAC_KEY\"},\"retries\":{\"policy\":\"constant\",\"delaySeconds\":2,\"attempts\":3}}"
waha -X POST -H "Content-Type: application/json" \
  -d "{\"name\":\"$SESSION\",\"config\":{\"webhooks\":[$WEBHOOK_JSON]}}" "$WAHA_URL/api/sessions" >/dev/null
waha -X POST "$WAHA_URL/api/sessions/$SESSION/start" >/dev/null
mkdir -p "$QR_DIR"
echo "  En el móvil del número secundario: WhatsApp › Dispositivos vinculados › Vincular dispositivo"
echo "  Te abro el QR en el navegador (se actualiza solo)…"
opened=0
status=""
elapsed=0
while [ "$elapsed" -lt "$QR_TIMEOUT_SECONDS" ]; do
  status="$(waha "$WAHA_URL/api/sessions/$SESSION" | json_get status || true)"
  [ "$status" = "WORKING" ] && break
  [ "$status" = "FAILED" ] && fail "La sesión de WhatsApp falló. Mira: docker logs jarvis-waha"
  if [ "$status" = "SCAN_QR_CODE" ]; then
    waha -H "Accept: image/png" -o "$QR_DIR/qr.tmp" "$WAHA_URL/api/$SESSION/auth/qr?format=image" && mv -f "$QR_DIR/qr.tmp" "$QR_DIR/qr.png"
    if [ "$opened" = "0" ]; then open "$QR_DIR/qr.html" 2>/dev/null || echo "  Abre a mano: $QR_DIR/qr.html"; opened=1; fi
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
rm -f "$QR_DIR/qr.png"
[ "$status" = "WORKING" ] || fail "No se escaneó el QR en 5 minutos. Vuelve a ejecutar el paso borrando config.env si hace falta."
ok "WhatsApp vinculado"

# ---------------------------------------------------------------------------
step "6/8 · Guardo tu configuración"
OWNER_LID="$(waha "$WAHA_URL/api/contacts/check-exists?phone=$OWNER_PHONE&session=$SESSION" | json_get chatId || true)"
[ -n "$OWNER_LID" ] || fail "Tu número personal +$OWNER_PHONE no aparece en WhatsApp"
cat > "$ROOT/config.env" <<EOF
OWNER_NAME=$OWNER_NAME
OWNER_ABOUT=$OWNER_ABOUT
OWNER_PHONE=$OWNER_PHONE
OWNER_CHAT_ID=$OWNER_PHONE@c.us
OWNER_LID=$OWNER_LID
TZ=$TZ_VALUE
WAHA_SESSION=$SESSION
CLAUDE_BIN=$(command -v claude)
WHISPER_URL=http://127.0.0.1:9000
WHISPER_LANGUAGE=es
EOF
[ -f "$ROOT/perfil/emisor.txt" ] || cp "$ROOT/perfil/emisor.example.txt" "$ROOT/perfil/emisor.txt"
ok "config.env creado · rellena tus datos de empresa en perfil/emisor.txt para los contratos"

# ---------------------------------------------------------------------------
step "7/8 · Lo dejo siempre encendido (arranca solo al iniciar sesión)"
mkdir -p "$ROOT/logs" "$HOME/Library/LaunchAgents"
TOOL_PATH="$(dirname "$(command -v node)"):$(dirname "$(command -v docker)"):$(dirname "$(command -v claude)"):/usr/bin:/bin:/usr/sbin:/sbin"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$ROOT/scripts/start-jarvis.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$TOOL_PATH</string></dict>
  <key>StandardOutPath</key><string>$ROOT/logs/launchd.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/launchd.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' http://127.0.0.1:3100/webhook || true)"
  [ "$code" = "401" ] && break
  sleep 2
done
[ "$code" = "401" ] || fail "El puente no arrancó. Mira: $ROOT/logs/start.log y $ROOT/logs/bridge-console.log"
ok "Puente en marcha (y se reinicia solo si se cae)"

# ---------------------------------------------------------------------------
step "8/8 · Prueba: te escribo por WhatsApp"
waha -X POST -H "Content-Type: application/json" \
  -d "{\"session\":\"$SESSION\",\"chatId\":\"$OWNER_PHONE@c.us\",\"text\":\"Hola $OWNER_NAME, soy Jarvis. Ya estoy listo: escríbeme o mándame una nota de voz.\"}" \
  "$WAHA_URL/api/sendText" >/dev/null
ok "Mensaje enviado a +$OWNER_PHONE"
printf '\n\033[1m¡Listo!\033[0m Escríbele a tu número secundario desde tu WhatsApp personal.\n'
