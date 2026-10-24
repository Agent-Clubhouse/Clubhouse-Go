// Isolated protocol fixture. All keys/tokens are fake and temporary. Never loads
// a Clubhouse profile, invokes agents, uses system trust, or binds beyond loopback.
import https from 'node:https';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, chmodSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { X509Certificate } from 'node:crypto';
const directory = mkdtempSync(join(tmpdir(), 'clubhouse-tls-test-'));
chmodSync(directory, 0o700);
const certPath = join(directory, 'certificate.pem');
const keyPath = join(directory, 'key.pem');
const generated = spawnSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyPath, '-out', certPath, '-days', '1', '-subj', '/CN=isolated-test'], { stdio: 'ignore' });
if (generated.status !== 0) { rmSync(directory, { recursive: true, force: true }); process.exit(1); }
chmodSync(keyPath, 0o600);
const cert = readFileSync(certPath);
let received = 0;
const server = https.createServer({ cert, key: readFileSync(keyPath), requestCert: true, rejectUnauthorized: false }, (req, res) => {
  received += 1;
  if (req.url === '/redirect') { res.writeHead(302, { Location: '/secret-destination' }); res.end(); return; }
  if (req.url === '/large') { res.writeHead(200); res.end('x'.repeat(4096)); return; }
  const peer = req.socket.getPeerCertificate();
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify({ clientCN: peer.subject?.CN ?? null, certificateFingerprint: peer.fingerprint256 ?? null, authorized: req.headers.authorization === 'Bearer fake-only', received }));
});
server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  process.stdout.write(JSON.stringify({ port: address.port, pin: new X509Certificate(cert).fingerprint256 }) + '\n');
});
function cleanup() { server.close(); rmSync(directory, { recursive: true, force: true }); process.exit(0); }
process.on('SIGTERM', cleanup);
process.on('SIGINT', cleanup);
