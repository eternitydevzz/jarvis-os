# Jarvis OS

Tu asistente personal en WhatsApp, con Claude como cerebro.
Le escribes o le mandas notas de voz desde tu WhatsApp personal; él te contesta, te prepara mensajes para tus clientes y **solo los envía cuando tú respondes `sí N`**.

Todo corre en tu Mac: WhatsApp (WAHA), la transcripción de audios (Whisper) y el puente con Claude Code.

## Antes de empezar (una sola vez)

| Necesitas | Cómo |
|---|---|
| Docker Desktop | [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/) · ábrelo una vez y acepta los permisos |
| Node 22 o más | `brew install node` |
| Claude Code con **tu propia** cuenta de Claude | `brew install --cask claude-code` → abre `claude` → `/login` |
| Un **número secundario** de WhatsApp en un móvil | Será el número de Jarvis. Tus clientes verán ese número |
| ~4 GB libres y buena conexión | La primera instalación descarga ~2-3 GB |

## Instalar (un comando)

Clónalo en tu carpeta personal, **no** en Escritorio ni Documentos (macOS puede bloquear el arranque automático ahí):

```bash
cd ~ && git clone https://github.com/jsegomeez-collab/jarvis-os.git && cd jarvis-os && bash scripts/setup.sh
```

El instalador te pide tu nombre, a qué te dedicas y tu WhatsApp **personal**. Luego te abre un QR: escanéalo con el móvil del número **secundario** (WhatsApp › Dispositivos vinculados › Vincular dispositivo). Al terminar te llega un "Hola, soy Jarvis".

**Para los contratos:** rellena los datos de tu empresa en `perfil/emisor.txt` (el instalador lo crea). Se leen en cada mensaje y nunca se suben a git.

**Para los enlaces de pago (opcional):** en Stripe › Desarrolladores › Claves de API › *Crear clave restringida* › *Elige la tuya*, da **Escritura** solo a **Products**, **Prices** y **Payment Links** (todo lo demás en *Ninguno*). Pega la clave en `.secrets/stripe.env` como `STRIPE_API_KEY=rk_live_…`. Sin ella, Jarvis funciona igual pero sin enlaces de pago.

## Cómo se usa

| Le dices | Qué pasa |
|---|---|
| Cualquier mensaje o nota de voz | Te contesta. Las notas de voz te las transcribe primero («Te entendí: …») |
| «Haz seguimiento a Ana (+34600111222) sobre la propuesta» | Te enseña un **Borrador N** con el texto exacto |
| «Hazme un contrato de mentoría para Ana, 3 meses, 1.500 USD…» | Te llega el contrato en **Word** por WhatsApp (borrador: revísalo) |
| «Envíaselo a Ana (+34600111222)» | **Borrador N** con el Word adjunto; se envía con `sí N` |
| «Enlace de pago de 1.500 USD por la mentoría de Ana» o «enlace del plan VIP» | Te llega el enlace de Stripe (crearlo no cobra nada) |
| «…y mándaselo a Ana (+34600111222)» | **Borrador N** con el enlace dentro; se envía con `sí N` |
| `sí N` (escrito) | El borrador se envía. Por voz no vale, a propósito |
| `no N` | El borrador se descarta |
| `/nuevo` | Empieza una conversación desde cero |

## Seguridad

- **Solo tu WhatsApp personal le da órdenes.** Lo que escriban otros (texto o audio) te llega reenviado como información; nunca lo obedece.
- **Nada sale sin tu `sí N`.** Claude no tiene herramientas: el envío lo hace el puente, no Claude.
- WAHA, Whisper y el puente solo escuchan en tu Mac (`127.0.0.1`). Las claves se generan en tu Mac y viven en `.secrets/`, fuera de git.
- Cada persona usa **su propia** cuenta de Claude.

## Si algo falla

| Problema | Qué hacer |
|---|---|
| No contesta | Mira `logs/start.log` y `logs/bridge.log` |
| Reiniciar Jarvis | `launchctl kickstart -k gui/$(id -u)/com.jarvis.agent` |
| Apagarlo | `launchctl bootout gui/$(id -u)/com.jarvis.agent` |
| Volver a vincular WhatsApp | Borra `config.env`, `.secrets/` y `waha/.sessions/` y repite `bash scripts/setup.sh` |

Si el Mac se duerme, Jarvis no contesta hasta que despierte.

## En Windows

Funciona igual con Docker Desktop: `scripts/start-jarvis.ps1` y `scripts/install-task.ps1` (tarea programada al iniciar sesión). El instalador de un comando es, de momento, solo para Mac.
