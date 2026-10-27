// Jarvis · puente WhatsApp (WAHA) ↔ Claude CLI.
// Solo el dueño conversa con Claude; lo que escriben otros se le reenvía, nunca se obedece.
// Claude solo redacta borradores [[ENVIAR|...]]; el puente los envía cuando el dueño responde "sí N".
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = 3100;
const CLAUDE_TIMEOUT_MS = 180_000;
const MAX_BODY_BYTES = 1_000_000;
const MAX_SEEN_IDS = 500;

function loadEnv(file) {
  const vars = {};
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (m) vars[m[1]] = m[2].trim();
  }
  return vars;
}

const env = {
  ...loadEnv(path.join(ROOT, 'config.env')),
  ...loadEnv(path.join(ROOT, '.secrets', 'waha.env')),
  ...loadEnv(path.join(ROOT, '.secrets', 'bridge.env')),
};
const REQUIRED = ['OWNER_NAME', 'OWNER_ABOUT', 'OWNER_CHAT_ID', 'OWNER_LID', 'WAHA_URL', 'WAHA_API_KEY', 'WAHA_SESSION', 'WEBHOOK_HMAC_KEY', 'CLAUDE_BIN'];
for (const key of REQUIRED) {
  if (!env[key]) {
    console.error(`Falta ${key} en config.env o .secrets/`);
    process.exit(1);
  }
}

const OWNER_IDS = new Set([env.OWNER_CHAT_ID, env.OWNER_LID]);
const WORKSPACE = path.join(ROOT, 'workspace');
const SESSION_FILE = path.join(WORKSPACE, 'session.json');
const PENDING_FILE = path.join(WORKSPACE, 'pending.json');
const DRAFT_BLOCK = /\[\[ENVIAR\|\+?([\d\s]{8,20})\|([^\]\n]{1,60})\]\]\s*([\s\S]*?)\s*\[\[\/ENVIAR\]\]/g;
const APPROVAL = /^(s[ií]|no)\s+(\d+)$/i;
const WHISPER_URL = env.WHISPER_URL || 'http://127.0.0.1:9000';
const WHISPER_LANGUAGE = env.WHISPER_LANGUAGE || 'es';
const MCP_NONE = path.join(ROOT, 'bridge', 'mcp-none.json');
const SYSTEM_PROMPT = fs.readFileSync(path.join(ROOT, 'bridge', 'system-prompt.txt'), 'utf8')
  .replaceAll('{{OWNER_NAME}}', env.OWNER_NAME)
  .replaceAll('{{OWNER_ABOUT}}', env.OWNER_ABOUT);
const LOG_FILE = path.join(ROOT, 'logs', 'bridge.log');
fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
fs.mkdirSync(WORKSPACE, { recursive: true });

// Solo metadatos en el log, nunca el texto de los mensajes.
function log(msg) {
  const line = `${new Date().toISOString()} ${msg}\n`;
  fs.appendFileSync(LOG_FILE, line);
  process.stdout.write(line);
}

async function sendText(chatId, text) {
  const res = await fetch(`${env.WAHA_URL}/api/sendText`, {
    method: 'POST',
    headers: { 'X-Api-Key': env.WAHA_API_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ session: env.WAHA_SESSION, chatId, text }),
  });
  if (!res.ok) throw new Error(`WAHA sendText HTTP ${res.status}`);
}

function isAudio(p) {
  return Boolean(p.hasMedia && p.media?.mimetype?.startsWith('audio/'));
}

// Descarga el audio de WAHA (solo de WAHA: se ignora el host que venga en la URL) y lo pasa a texto con Whisper.
async function transcribe(media) {
  if (media.error || !media.url) throw new Error('WAHA no pudo descargar el audio');
  const { pathname, search } = new URL(media.url);
  const audio = await fetch(`${env.WAHA_URL}${pathname}${search}`, { headers: { 'X-Api-Key': env.WAHA_API_KEY } });
  if (!audio.ok) throw new Error(`WAHA archivo HTTP ${audio.status}`);

  const form = new FormData();
  form.append('audio_file', new Blob([await audio.arrayBuffer()], { type: media.mimetype }), 'nota-de-voz.ogg');
  const params = `task=transcribe&language=${WHISPER_LANGUAGE}&output=text&vad_filter=true`;
  const res = await fetch(`${WHISPER_URL}/asr?${params}`, { method: 'POST', body: form });
  if (!res.ok) throw new Error(`Whisper HTTP ${res.status}`);
  return (await res.text()).trim();
}

// Devuelve el chatId de WhatsApp del número, o null si no tiene WhatsApp.
async function whatsappChatId(phone) {
  const url = `${env.WAHA_URL}/api/contacts/check-exists?phone=${phone}&session=${env.WAHA_SESSION}`;
  const res = await fetch(url, { headers: { 'X-Api-Key': env.WAHA_API_KEY } });
  if (!res.ok) throw new Error(`WAHA check-exists HTTP ${res.status}`);
  const data = await res.json();
  return data.numberExists ? data.chatId : null;
}

function readPending() {
  if (!fs.existsSync(PENDING_FILE)) return { next: 1, items: {} };
  return JSON.parse(fs.readFileSync(PENDING_FILE, 'utf8'));
}

function savePending(pending) {
  fs.writeFileSync(PENDING_FILE, JSON.stringify(pending, null, 2));
}

function addPending(draft) {
  const pending = readPending();
  const n = pending.next;
  savePending({ next: n + 1, items: { ...pending.items, [n]: { ...draft, createdAt: new Date().toISOString() } } });
  return n;
}

function removePending(n) {
  const pending = readPending();
  const { [n]: _removed, ...items } = pending.items;
  savePending({ ...pending, items });
}

function extractDrafts(reply) {
  const drafts = [];
  const visible = reply.replace(DRAFT_BLOCK, (_, phone, name, text) => {
    drafts.push({ phone: phone.replace(/\s/g, ''), name: name.trim(), text: text.trim() });
    return '';
  }).trim();
  return { visible, drafts };
}

// Lo que pasó con los borradores se le cuenta a Claude en el siguiente mensaje.
const notesForClaude = [];

function readSessionId() {
  if (!fs.existsSync(SESSION_FILE)) return null;
  return JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8')).id ?? null;
}

function saveSessionId(id) {
  fs.writeFileSync(SESSION_FILE, JSON.stringify({ id }));
}

function runClaude(prompt, sessionId) {
  const args = [
    '-p', '--output-format', 'json',
    '--tools', '',
    '--setting-sources', 'project',
    '--strict-mcp-config', '--mcp-config', MCP_NONE,
    '--system-prompt', SYSTEM_PROMPT,
    '--system-prompt-snapshot', 'off', // si no, al reanudar reutiliza el prompt grabado y ignora cambios
  ];
  if (sessionId) args.push('--resume', sessionId);

  return new Promise((resolve, reject) => {
    const child = spawn(env.CLAUDE_BIN, args, { cwd: WORKSPACE, windowsHide: true });
    let out = '';
    let err = '';
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('Claude tardó más de 3 minutos'));
    }, CLAUDE_TIMEOUT_MS);

    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err += d; });
    child.on('error', (e) => { clearTimeout(timer); reject(e); });
    child.on('close', (code) => {
      clearTimeout(timer);
      let result;
      try {
        result = JSON.parse(out);
      } catch {
        reject(new Error(`Claude salió con código ${code}: ${err.slice(0, 200)}`));
        return;
      }
      if (result.is_error) reject(new Error(result.result || 'error de Claude'));
      else resolve({ text: result.result, sessionId: result.session_id });
    });
    child.stdin.end(prompt);
  });
}

async function askClaude(text) {
  const now = new Date().toLocaleString('es-ES', { timeZone: env.TZ || 'Europe/Madrid' });
  const notes = notesForClaude.splice(0).map((n) => `[Nota del sistema: ${n}]\n`).join('');
  const prompt = `${notes}[${now}] ${text}`;
  const sessionId = readSessionId();
  try {
    const r = await runClaude(prompt, sessionId);
    saveSessionId(r.sessionId);
    return r.text;
  } catch (e) {
    if (!sessionId) throw e;
    log(`no pude continuar la conversación (${e.message}); empiezo una nueva`);
    const r = await runClaude(prompt, null);
    saveSessionId(r.sessionId);
    return r.text;
  }
}

async function handleOwner(p) {
  if (isAudio(p)) {
    await handleOwnerVoice(p);
    return;
  }
  const text = (p.body || '').trim();
  if (text.toLowerCase() === '/nuevo') {
    fs.rmSync(SESSION_FILE, { force: true });
    await sendText(p.from, 'Listo, empiezo una conversación nueva.');
    return;
  }
  if (!text) {
    await sendText(p.from, 'De momento entiendo texto y notas de voz. Fotos y archivos llegarán más adelante.');
    return;
  }
  const approval = text.match(APPROVAL);
  if (approval) {
    await handleApproval(p.from, approval[1].toLowerCase(), Number(approval[2]));
    return;
  }
  await converse(p.from, text);
}

// Las notas de voz nunca aprueban borradores: el "sí N" tiene que ir escrito.
async function handleOwnerVoice(p) {
  let transcript;
  try {
    transcript = await transcribe(p.media);
  } catch (e) {
    log(`ERROR transcripción: ${e.message}`);
    await sendText(p.from, `No pude escuchar tu nota de voz: ${e.message}`);
    return;
  }
  log(`nota de voz del dueño transcrita (${transcript.length} car.)`);
  if (!transcript) {
    await sendText(p.from, 'No oí nada en la nota de voz. ¿Me la repites?');
    return;
  }
  await sendText(p.from, `🎙️ _Te entendí:_ «${transcript}»`);
  await converse(p.from, `[Nota de voz transcrita] ${transcript}`);
}

async function converse(ownerChat, text) {
  log(`dueño → Claude (${text.length} car.)`);
  let reply;
  try {
    reply = await askClaude(text);
  } catch (e) {
    log(`ERROR Claude: ${e.message}`);
    reply = `No pude responderte: ${e.message}`;
  }
  const { visible, drafts } = extractDrafts(reply);
  if (visible) await sendText(ownerChat, visible);
  for (const d of drafts) {
    const n = addPending(d);
    log(`borrador ${n} creado para ${d.phone}`);
    await sendText(ownerChat, `📤 *Borrador ${n}* para *${d.name}* (+${d.phone}):\n\n${d.text}\n\nResponde *sí ${n}* para enviarlo o *no ${n}* para descartarlo.`);
  }
  log(`Claude → dueño (${visible.length} car., ${drafts.length} borradores)`);
}

// Las aprobaciones las resuelve el puente, nunca Claude.
async function handleApproval(ownerChat, verb, n) {
  const item = readPending().items[n];
  if (!item) {
    await sendText(ownerChat, `No tengo ningún borrador ${n} pendiente.`);
    return;
  }
  if (verb === 'no') {
    removePending(n);
    notesForClaude.push(`${env.OWNER_NAME} descartó el borrador ${n} para ${item.name}.`);
    await sendText(ownerChat, `🗑️ Borrador ${n} descartado.`);
    return;
  }
  const chatId = await whatsappChatId(item.phone);
  if (!chatId) {
    await sendText(ownerChat, `El número +${item.phone} no tiene WhatsApp; no envié el borrador ${n}.`);
    return;
  }
  await sendText(chatId, item.text);
  removePending(n);
  log(`borrador ${n} enviado a ${item.phone} tras aprobación`);
  notesForClaude.push(`Se envió el borrador ${n} a ${item.name} (+${item.phone}).`);
  await sendText(ownerChat, `✅ Enviado a ${item.name} (+${item.phone}).`);
}

// Otros remitentes: información para el dueño, nunca instrucciones para Jarvis.
async function handleOther(p) {
  const who = p._data?.notifyName || p.from;
  let body = (p.body || '').trim() || (p.hasMedia ? '[archivo]' : '[mensaje vacío]');
  if (isAudio(p)) {
    try {
      body = `🎙️ Nota de voz: «${await transcribe(p.media)}»`;
    } catch (e) {
      log(`ERROR transcripción de ${p.from}: ${e.message}`);
      body = '🎙️ [nota de voz que no pude transcribir]';
    }
  }
  log(`mensaje de ${p.from} → reenviado al dueño`);
  await sendText(env.OWNER_CHAT_ID, `📩 *${who}* (${p.from}) te escribió:\n\n${body}\n\n_Solo te lo reenvío; no he hecho nada._`);
}

function shouldIgnore(p) {
  if (!p || p.fromMe || !p.from) return true;
  return p.from.endsWith('@g.us') || p.from.endsWith('@newsletter') || p.from === 'status@broadcast';
}

function validHmac(raw, header) {
  if (!header) return false;
  const expected = Buffer.from(crypto.createHmac('sha512', env.WEBHOOK_HMAC_KEY).update(raw).digest('hex'));
  const given = Buffer.from(String(header));
  return expected.length === given.length && crypto.timingSafeEqual(expected, given);
}

let queue = Promise.resolve();
function enqueue(task) {
  queue = queue.then(task).catch((e) => log(`ERROR ${e.message}`));
}

const seen = new Set();

const server = http.createServer((req, res) => {
  if (req.method !== 'POST' || req.url !== '/webhook') {
    res.writeHead(404).end();
    return;
  }
  const chunks = [];
  let size = 0;
  req.on('data', (c) => {
    size += c.length;
    if (size > MAX_BODY_BYTES) req.destroy();
    else chunks.push(c);
  });
  req.on('end', () => {
    const raw = Buffer.concat(chunks);
    if (!validHmac(raw, req.headers['x-webhook-hmac'])) {
      log('webhook rechazado: firma HMAC inválida');
      res.writeHead(401).end();
      return;
    }
    res.writeHead(200).end('ok');

    let evt;
    try {
      evt = JSON.parse(raw);
    } catch {
      log('webhook con JSON inválido');
      return;
    }
    const p = evt.payload;
    if (evt.event !== 'message' || shouldIgnore(p)) return;

    const id = String(p.id);
    if (seen.has(id)) return;
    seen.add(id);
    if (seen.size > MAX_SEEN_IDS) seen.delete(seen.values().next().value);

    enqueue(() => (OWNER_IDS.has(p.from) ? handleOwner(p) : handleOther(p)));
  });
});

server.listen(PORT, '127.0.0.1', () => log(`puente escuchando en 127.0.0.1:${PORT}`));
