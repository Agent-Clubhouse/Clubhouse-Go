import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { test } from 'node:test';
import { rememberPairingPin, writePairingInvitation } from './pairing-fixture.ts';

const root = path.resolve(import.meta.dirname, '..', '..');
fs.mkdirSync(path.join(root, 'build'), { recursive: true });

function fixtureDir(t: { after: (cleanup: () => void) => void }) {
  const dir = fs.mkdtempSync(path.join(root, 'build', 'pairing-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true }));
  return dir;
}

/** The pinned desktop contract: a PIN is spent before /pair succeeds; only the same identity/cert can retry it. */
function desktop() {
  let generation = 1;
  const spent = new Map<string, string>();
  const status = {
    tlsEnabled: true, advertising: false, pairingPaused: false, port: 43210,
    fingerprint: 'fixture-host', tlsCertificateFingerprint: 'AA:BB:CC', pin: '000001',
  };
  const rotate = () => { status.pin = String(++generation).padStart(6, '0'); };
  return {
    status,
    rotate,
    pair(pin: string, identityAndCert: string) {
      if (spent.has(pin)) return spent.get(pin) === identityAndCert ? 200 : 410;
      if (pin !== status.pin) return 410;
      spent.set(pin, identityAndCert);
      rotate();
      return 200;
    },
    getStatus: async () => ({ ...status }),
  };
}

test('observer, every phone, retry and relaunch read the current one-use PIN', async t => {
  const dir = fixtureDir(t);
  const server = desktop();
  const observerStatus = await server.getStatus();
  rememberPairingPin(dir, observerStatus.pin);
  assert.equal(server.pair(observerStatus.pin, 'observer'), 200);
  assert.equal(server.pair(observerStatus.pin, 'first-phone'), 410);
  assert.equal(server.pair(observerStatus.pin, 'observer'), 200);
  assert.equal(fs.existsSync(path.join(dir, 'invitation.json')), false);

  const issued: string[] = [observerStatus.pin];
  for (const identity of ['first-phone', 'second-test', 'test-retry', 'relaunch', 'launch-timeout-retry']) {
    await writePairingInvitation(dir, server.getStatus);
    const file = path.join(dir, 'invitation.json');
    const invitation = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.deepEqual(invitation, {
      host: '127.0.0.1', port: 43210, hostID: 'fixture-host',
      certificatePin: 'aabbcc', pin: server.status.pin, name: 'E2E Fixture Desktop',
    });
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    assert.equal(fs.existsSync(`${file}.pending`), false);
    assert.equal(server.pair(invitation.pin, identity), 200);
    assert.equal(server.pair(invitation.pin, `${identity}-different-cert`), 410);
    issued.push(invitation.pin);
  }
  assert.equal(new Set(issued).size, issued.length);
  const history = fs.readdirSync(dir).filter(name => /^invitation-.*\.json$/.test(name));
  assert.deepEqual(history.map(name => {
    const file = path.join(dir, name);
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    return JSON.parse(fs.readFileSync(file, 'utf8')).pin;
  }).sort(), issued.sort());
});

test('build delays, unused invitations and simulator restarts never freeze an old PIN', async t => {
  const dir = fixtureDir(t);
  const server = desktop();
  server.rotate(); // A build can outlast the desktop's ten-minute PIN lifetime.
  await writePairingInvitation(dir, server.getStatus);
  const unused = JSON.parse(fs.readFileSync(path.join(dir, 'invitation.json'), 'utf8'));
  server.rotate(); // The phone never paired on its failed launch.
  assert.equal(server.pair(unused.pin, 'failed-launch'), 410);
  await writePairingInvitation(dir, server.getStatus);
  const current = JSON.parse(fs.readFileSync(path.join(dir, 'invitation.json'), 'utf8'));
  assert.notEqual(current.pin, unused.pin);
  assert.equal(server.pair(current.pin, 'restarted-runner'), 200);
});

test('dry-run the full Swift suite launch plan, including explicit relaunches and retries', async t => {
  const dir = fixtureDir(t);
  const server = desktop();
  assert.equal(server.pair(server.status.pin, 'observer'), 200);
  const source = fs.readFileSync(path.join(root, 'Annex/AnnexUITests/CompanionLiveE2ETests.swift'), 'utf8');
  const methods = [...source.matchAll(/^    func (test\w+)\(/gm)];
  const plan = methods.map((method, index) => ({
    name: method[1],
    launches: [...source.slice(method.index, methods[index + 1]?.index).matchAll(/\blaunchPaired\(/g)].length,
  })).sort((a, b) => a.name.localeCompare(b.name));
  assert.ok(plan.length > 0 && plan.every(method => method.launches > 0));
  let pairings = 0;
  for (const phase of ['suite', 'failed-test-retry', 'simulator-restart']) {
    for (const method of plan) {
      for (let launch = 0; launch < method.launches; launch++) {
        // Even a timed-out launch may already have paired before XCTest retries it.
        for (let attempt = 0; attempt < 3; attempt++) {
          await writePairingInvitation(dir, server.getStatus);
          const invitation = JSON.parse(fs.readFileSync(path.join(dir, 'invitation.json'), 'utf8'));
          assert.equal(server.pair(invitation.pin, `${phase}-${method.name}-${launch}-${attempt}`), 200);
          pairings++;
        }
      }
    }
  }
  t.diagnostic(`${plan.length} methods (including opt-in icons), ${plan.reduce((sum, method) => sum + method.launches, 0)} launches per pass; ${pairings} fresh phone pairings`);
});

test('unavailable, paused or non-isolated Annex fails rather than publishing an invitation', async t => {
  const dir = fixtureDir(t);
  for (const invalid of [{ tlsEnabled: false }, { advertising: true }, { pairingPaused: true },
    { port: 0 }, { fingerprint: '' }, { tlsCertificateFingerprint: '' }, { pin: '' }]) {
    const server = desktop();
    Object.assign(server.status, invalid);
    await assert.rejects(writePairingInvitation(dir, server.getStatus), /not ready/);
    assert.equal(fs.existsSync(path.join(dir, 'invitation.json')), false);
  }
  await assert.rejects(writePairingInvitation(dir, async () => { throw new Error('Desktop exited'); }), /Desktop exited/);
});
