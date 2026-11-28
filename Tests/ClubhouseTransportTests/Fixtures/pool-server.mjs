// Isolated URLSession connection-pool probe fixture. Node built-ins only; all keys are fake
// and temporary. Binds loopback only, never loads a Clubhouse profile or system trust.
//
// Mirrors the desktop's main server shape (Clubhouse src/main/services/annex-server.ts:4864 and
// annex-tls.ts:182): `https.createServer({ cert, key, requestCert: true, rejectUnauthorized: false })`
// with no ALPNProtocols, so TLS negotiates HTTP/1.1 exactly as the desktop does.
//
// TLS server:
//   GET /hold?id=X  -> recorded on arrival, then held (no response bytes) until released or the socket closes
//   GET /trickle?id=X -> 200 headers, then one body byte every 2 s until released or the socket closes
//   GET /fast?id=X  -> recorded on arrival, answered immediately (keep-alive)
//   GET /ws         -> RFC 6455 upgrade, greeting text frame, pongs every ping (each ping recorded)
// Plain HTTP control server (separate port, so a separate URLSession pool):
//   GET /stats            -> { accepted, open, maxOpen, arrivals, pings, closedHolds }
//   GET /release?id=X|all -> answers held requests with 200
import https from 'node:https';
import http from 'node:http';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, chmodSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { X509Certificate, createHash } from 'node:crypto';

const directory = mkdtempSync(join(tmpdir(), 'clubhouse-pool-test-'));
chmodSync(directory, 0o700);
const certPath = join(directory, 'certificate.pem');
const keyPath = join(directory, 'key.pem');
const generated = spawnSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyPath, '-out', certPath, '-days', '1', '-subj', '/CN=isolated-test'], { stdio: 'ignore' });
if (generated.status !== 0) { rmSync(directory, { recursive: true, force: true }); process.exit(1); }
chmodSync(keyPath, 0o600);
const cert = readFileSync(certPath);
const key = readFileSync(keyPath);
rmSync(directory, { recursive: true, force: true });

const started = performance.now();
const now = () => Math.round((performance.now() - started) * 10) / 10;
let accepted = 0, open = 0, maxOpen = 0;
const arrivals = [];
const pings = [];
const closedHolds = [];
const held = new Map();

function frame(opcode, payload) {
  return Buffer.concat([Buffer.from([0x80 | opcode, payload.length]), payload]);
}

const server = https.createServer({ cert, key, requestCert: true, rejectUnauthorized: false }, (req, res) => {
  const url = new URL(req.url, 'https://fixture.invalid');
  const id = url.searchParams.get('id') ?? '';
  arrivals.push({ path: url.pathname, id, t: now(), socket: req.socket.probeID, alpn: req.socket.alpnProtocol || null, httpVersion: req.httpVersion });
  if (url.pathname === '/hold') {
    held.set(id, res);
    res.on('close', () => { if (held.get(id) === res) { held.delete(id); closedHolds.push({ id, t: now() }); } });
    return;
  }
  if (url.pathname === '/trickle') { // a slow but live read: one body byte every 2 s, never finishing on its own
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    const timer = setInterval(() => res.write('.'), 2000);
    held.set(id, res);
    res.on('close', () => { clearInterval(timer); if (held.get(id) === res) { held.delete(id); closedHolds.push({ id, t: now() }); } });
    return;
  }
  if (url.pathname === '/fast') { res.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Length': 2 }); res.end('ok'); return; }
  res.writeHead(404); res.end();
});
server.keepAliveTimeout = 60_000;
server.on('secureConnection', (socket) => {
  socket.probeID = ++accepted; open += 1; maxOpen = Math.max(maxOpen, open);
  socket.on('close', () => { open -= 1; });
});
server.on('upgrade', (req, socket) => {
  arrivals.push({ path: '/ws', id: '', t: now(), socket: socket.probeID, alpn: socket.alpnProtocol || null, httpVersion: req.httpVersion });
  const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(['HTTP/1.1 101 Switching Protocols', 'Upgrade: websocket', 'Connection: Upgrade', `Sec-WebSocket-Accept: ${accept}`, '', ''].join('\r\n'));
  socket.write(frame(1, Buffer.from('hello')));
  let buffer = Buffer.alloc(0);
  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      if (buffer.length < 2) return;
      const opcode = buffer[0] & 0x0f;
      const masked = (buffer[1] & 0x80) !== 0;
      const length = buffer[1] & 0x7f; // control frames and probe texts are < 126 bytes
      const offset = 2 + (masked ? 4 : 0);
      if (buffer.length < offset + length) return;
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= buffer[2 + (i % 4)];
      buffer = buffer.subarray(offset + length);
      if (opcode === 0x8) { socket.end(frame(0x8, payload.subarray(0, 2))); return; }
      if (opcode === 0x9) { pings.push({ t: now(), socket: socket.probeID }); socket.write(frame(0xA, payload)); continue; }
      if (opcode === 0x1) socket.write(frame(1, payload));
    }
  });
  socket.on('error', () => {});
});

const control = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://control.invalid');
  if (url.pathname === '/release') {
    const id = url.searchParams.get('id');
    for (const [key, pending] of [...held]) {
      if (id !== 'all' && key !== id) continue;
      held.delete(key);
      if (pending.headersSent) pending.end(); else { pending.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Length': 4 }); pending.end('held'); }
    }
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ accepted, open, maxOpen, held: held.size, arrivals, pings, closedHolds, t: now() }));
});

let ready = 0;
function announce() {
  if (++ready < 2) return;
  process.stdout.write(JSON.stringify({ port: server.address().port, controlPort: control.address().port, pin: new X509Certificate(cert).fingerprint256 }) + '\n');
}
server.listen(0, '127.0.0.1', announce);
control.listen(0, '127.0.0.1', announce);
function cleanup() { server.closeAllConnections?.(); server.close(); control.close(); process.exit(0); }
process.on('SIGTERM', cleanup);
process.on('SIGINT', cleanup);
