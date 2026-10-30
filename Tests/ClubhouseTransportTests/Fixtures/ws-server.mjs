// Isolated WebSocket + OTLP fixture. Node built-ins only; all keys/tokens are fake and
// temporary. Binds loopback only, never loads a Clubhouse profile or system trust.
//
// TLS server (pinned self-signed certificate, optional client certificate):
//   GET /trace  -> 200 with a `traceparent` response header in the request's trace
//   GET /ws     -> RFC 6455 upgrade. Greets with a JSON text frame describing the request,
//                  then: text "binary" -> binary reply, "mute" -> stop answering pings and
//                  report each ping as a "got-ping" text frame, any other text -> echoed.
//                  Pings are answered with pongs; a close frame is answered and the socket ends.
// Plain HTTP server (OTLP collector stand-in): POST /ok, /empty, /busy, /bad, /huge, /redirect.
import https from 'node:https';
import http from 'node:http';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, chmodSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { X509Certificate, createHash, randomBytes } from 'node:crypto';

const directory = mkdtempSync(join(tmpdir(), 'clubhouse-ws-test-'));
chmodSync(directory, 0o700);
const certPath = join(directory, 'certificate.pem');
const keyPath = join(directory, 'key.pem');
const generated = spawnSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyPath, '-out', certPath, '-days', '1', '-subj', '/CN=isolated-test'], { stdio: 'ignore' });
if (generated.status !== 0) { rmSync(directory, { recursive: true, force: true }); process.exit(1); }
chmodSync(keyPath, 0o600);
const cert = readFileSync(certPath);
const key = readFileSync(keyPath);
rmSync(directory, { recursive: true, force: true });

function frame(opcode, payload) {
  const length = payload.length;
  let header;
  if (length < 126) { header = Buffer.from([0x80 | opcode, length]); }
  else if (length < 65536) { header = Buffer.alloc(4); header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(length, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x80 | opcode; header[1] = 127; header.writeBigUInt64BE(BigInt(length), 2); }
  return Buffer.concat([header, payload]);
}

const server = https.createServer({ cert, key, requestCert: true, rejectUnauthorized: false }, (req, res) => {
  if (req.url === '/trace') {
    const parent = req.headers.traceparent;
    const headers = { 'Content-Type': 'application/json' };
    if (parent) headers.traceparent = `00-${parent.split('-')[1]}-${randomBytes(8).toString('hex')}-01`;
    res.writeHead(200, headers);
    res.end(JSON.stringify({ traced: Boolean(parent) }));
    return;
  }
  res.writeHead(404); res.end();
});

server.on('upgrade', (req, socket) => {
  const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(['HTTP/1.1 101 Switching Protocols', 'Upgrade: websocket', 'Connection: Upgrade', `Sec-WebSocket-Accept: ${accept}`, '', ''].join('\r\n'));
  const peer = socket.getPeerCertificate();
  socket.write(frame(1, Buffer.from(JSON.stringify({
    path: req.url, authorized: req.headers.authorization === 'Bearer fake-only',
    clientCN: peer?.subject?.CN ?? null, traceparent: req.headers.traceparent ?? null,
  }))));
  let muted = false;
  let buffer = Buffer.alloc(0);
  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      if (buffer.length < 2) return;
      const opcode = buffer[0] & 0x0f;
      const masked = (buffer[1] & 0x80) !== 0;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
      else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
      const maskOffset = offset;
      if (masked) offset += 4;
      if (buffer.length < offset + length) return;
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= buffer[maskOffset + (i % 4)];
      buffer = buffer.subarray(offset + length);
      if (opcode === 0x8) { socket.end(frame(0x8, payload.subarray(0, 2))); return; }
      if (opcode === 0x9) {
        if (muted) socket.write(frame(1, Buffer.from('got-ping')));
        else socket.write(frame(0xA, payload));
        continue;
      }
      if (opcode === 0x1) {
        const text = payload.toString('utf8');
        if (text === 'binary') socket.write(frame(2, Buffer.from([0xde, 0xad, 0xbe, 0xef])));
        else if (text === 'mute') { muted = true; socket.write(frame(1, Buffer.from('muted'))); }
        else socket.write(frame(1, payload));
      }
    }
  });
  socket.on('error', () => {});
});

const collector = http.createServer((req, res) => {
  req.resume();
  req.on('end', () => {
    switch (req.url) {
      case '/ok': res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ partialSuccess: { rejectedSpans: 2 } })); break;
      case '/empty': res.writeHead(200); res.end(); break;
      case '/busy': res.writeHead(429, { 'Retry-After': '7' }); res.end('slow down'); break;
      case '/bad': res.writeHead(200); res.end('not json'); break;
      case '/huge': res.writeHead(200); res.end('x'.repeat(70 * 1024)); break;
      case '/redirect': res.writeHead(302, { Location: '/ok' }); res.end(); break;
      default: res.writeHead(404); res.end();
    }
  });
});

let ready = 0;
function announce() {
  if (++ready < 2) return;
  process.stdout.write(JSON.stringify({ port: server.address().port, httpPort: collector.address().port, pin: new X509Certificate(cert).fingerprint256 }) + '\n');
}
server.listen(0, '127.0.0.1', announce);
collector.listen(0, '127.0.0.1', announce);
function cleanup() { server.close(); collector.close(); process.exit(0); }
process.on('SIGTERM', cleanup);
process.on('SIGINT', cleanup);
