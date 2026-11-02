// Isolated loopback mTLS fixture: no Clubhouse state or agents. Fake, temporary keys only.
import https from 'node:https';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, chmodSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { X509Certificate } from 'node:crypto';
const directory = mkdtempSync(join(tmpdir(), 'clubhouse-command-refusal-'));
chmodSync(directory, 0o700);
const keyPath = join(directory, 'key.pem'), certPath = join(directory, 'cert.pem');
const generated = spawnSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyPath, '-out', certPath, '-days', '1', '-subj', '/CN=isolated-command-refusal'], { stdio: 'ignore' });
if (generated.status !== 0) { rmSync(directory, { recursive: true, force: true }); process.exit(1); }
chmodSync(keyPath, 0o600);
const cert = readFileSync(certPath), observations = [];
const body = Buffer.from(JSON.stringify({ version: 1, epoch: 'server-epoch', status: 'rejected', error: { code: 'too_large', message: 'too_large' } }));
const server = https.createServer({ cert, key: readFileSync(keyPath), requestCert: true, rejectUnauthorized: false }, (req, res) => {
  const peer = req.socket.getPeerCertificate();
  if (!peer.raw) { res.writeHead(401); res.end(); return; }
  if (req.url === '/observations') { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(observations)); return; }
  if (req.url !== '/api/v1/mobile/commands' || req.method !== 'POST' || Number(req.headers['content-length']) !== 1048577) { res.writeHead(400); res.end(); return; }
  const observation = { requestBytes: Number(req.headers['content-length']), receivedBytes: 0, responseStartedAtBytes: null, uploadEnded: false, responseEnded: false, connectionClosed: false, clientCN: peer.subject?.CN };
  observations.push(observation);
  req.on('error', () => {}); res.on('error', () => {});
  req.socket.on('close', () => { observation.connectionClosed = true; });
  res.on('finish', () => { observation.responseEnded = true; });
  // Send the refusal before the upload ends, then drain before ending/closing as CH #2710 does.
  // Wait for one body chunk only to make this probe cover an upload demonstrably in progress.
  const timer = setTimeout(() => res.end(), 10_000);
  const finish = () => { clearTimeout(timer); res.end(); };
  req.on('data', chunk => {
    observation.receivedBytes += chunk.length;
    if (!res.headersSent) {
      observation.responseStartedAtBytes = observation.receivedBytes;
      res.writeHead(413, { 'Content-Type': 'application/json', 'Content-Length': body.length, Connection: 'close' });
      res.write(body);
    }
  });
  req.on('end', () => { observation.uploadEnded = true; finish(); });
  req.on('aborted', finish);
});
server.listen(0, '127.0.0.1', () => process.stdout.write(JSON.stringify({ port: server.address().port, pin: new X509Certificate(cert).fingerprint256 }) + '\n'));
function cleanup() { server.close(); rmSync(directory, { recursive: true, force: true }); process.exit(0); }
process.on('SIGTERM', cleanup); process.on('SIGINT', cleanup);
