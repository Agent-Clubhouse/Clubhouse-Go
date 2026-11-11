import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';

type PairingStatus = {
  tlsEnabled: boolean;
  advertising: boolean;
  pairingPaused: boolean;
  port: number;
  fingerprint: string;
  tlsCertificateFingerprint: string;
  pin: string;
};

/** Retain every issued PIN privately until teardown, including the observer's, for log redaction. */
export function rememberPairingPin(fixtureDir: string, pin: string) {
  fs.writeFileSync(path.join(fixtureDir, `invitation-${crypto.randomUUID()}.json`), JSON.stringify({ pin }), { mode: 0o600 });
}

export async function writePairingInvitation(fixtureDir: string, getStatus: () => Promise<PairingStatus>) {
  const status = await getStatus();
  if (!status.tlsEnabled || status.advertising || status.pairingPaused ||
      !Number.isInteger(status.port) || status.port <= 0 || status.port > 65535 ||
      !status.fingerprint || !status.tlsCertificateFingerprint || !/^\d{6}$/.test(status.pin)) {
    throw new Error('Fixture Annex is not ready for loopback TLS pairing');
  }
  const invitation = {
    host: '127.0.0.1',
    port: status.port,
    hostID: status.fingerprint,
    certificatePin: status.tlsCertificateFingerprint.replace(/:/g, '').toLowerCase(),
    pin: status.pin,
    name: 'E2E Fixture Desktop',
  };
  rememberPairingPin(fixtureDir, status.pin);
  const file = path.join(fixtureDir, 'invitation.json');
  fs.writeFileSync(`${file}.pending`, JSON.stringify(invitation), { mode: 0o600 });
  fs.renameSync(`${file}.pending`, file);
}
