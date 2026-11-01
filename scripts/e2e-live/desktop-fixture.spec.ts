/**
 * Clubhouse desktop fixture for Clubhouse Go's live E2E suite (scripts/e2e-live.sh).
 *
 * The script copies this file into the desktop checkout's e2e/ folder and runs it with the desktop's own
 * Playwright, so it launches the real app (the webpack build, unpackaged) through the desktop's launch primitive:
 * a disposable profile, auto-update off, onboarding dismissed. Nothing here touches the user's own Clubhouse.
 *
 * - Annex runs loopback-only and ephemeral (CLUBHOUSE_ANNEX_LOOPBACK_ONLY=1, CLUBHOUSE_ANNEX_EPHEMERAL=1), so it
 *   doesn't advertise and keeps its identity, TLS and peers in memory.
 * - Every provider CLI is pinned through the unpackaged-only CLUBHOUSE_TEST_CLI_BINARIES seam. Claude Code is the
 *   desktop's scripted fake-claude.mjs (no model, no tokens); the others point at paths that don't exist, so a real
 *   CLI on this machine can never be reached.
 * - It adds one git project with two chat agents: "Echo" in the project folder and "Builder" in its own worktree.
 *
 * Once Annex listens it writes `invitation.json` (0600) to E2E_FIXTURE_DIR: {host, port, hostID, certificatePin,
 * pin, name}, the in-memory pairing that Clubhouse Go's DEBUG bootstrap takes in CLUBHOUSE_COMPANION_TEST_INVITATION.
 * Then it waits until `stop` appears in that folder and quits the app. Meanwhile a test can put an agent to sleep
 * on the desktop, as if stopped there, by writing its id to `sleep-request`; the fixture answers with `sleep-done`.
 */
import { test, expect } from '@playwright/test';
import { execFileSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';
import * as tls from 'tls';
import * as https from 'https';
import forge from 'node-forge';
import WebSocket from 'ws';
import { launchApp } from '../launch';

const FIXTURE_DIR = process.env.E2E_FIXTURE_DIR ?? '';
const DESKTOP = path.resolve(__dirname, '..', '..');
const FAKE_CLAUDE = path.join(DESKTOP, 'src', 'main', 'chat', 'claude', '__fixtures__', 'fake-claude.mjs');

function log(message: string) {
  process.stdout.write(`[desktop-fixture] ${message}\n`);
}

function writeFile(file: string, content: string, mode = 0o644) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content, { mode });
}

/** Defense in depth for fixture replies and wire evidence; secrets stay only in their private temp files. */
function evidence(value: unknown): string {
  const secrets: string[] = [];
  for (const file of fs.readdirSync(FIXTURE_DIR).filter(f => f === 'invitation.json' || /^mcp-.*\.json$/.test(f))) {
    const credentials = JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, file), 'utf8'));
    for (const key of ['pin', 'CLUBHOUSE_HOOK_NONCE']) {
      if (credentials[key]) secrets.push(String(credentials[key]));
    }
  }
  return JSON.stringify(value, (_key, item) => typeof item === 'string'
    ? secrets.reduce((text, secret) => text.split(secret).join('<redacted>'), item) : item);
}

/** A git repository with one commit, so a worktree agent can branch from it. */
function makeProject(dir: string) {
  writeFile(path.join(dir, 'README.md'), '# Phone E2E fixture\n\nA project the Clubhouse Go live suite drives.\n');
  writeFile(path.join(dir, 'src', 'phone-preview.txt'), 'PHONE_PREVIEW_CONFIRMED\n');
  const git = (...args: string[]) => execFileSync('git', args, { cwd: dir, stdio: 'ignore' });
  git('init', '-q', '-b', 'main');
  git('-c', 'user.name=E2E', '-c', 'user.email=e2e@example.invalid', 'add', '.');
  git('-c', 'user.name=E2E', '-c', 'user.email=e2e@example.invalid', 'commit', '-q', '-m', 'Fixture');
}

/** A `claude` executable that runs the desktop's scripted fake. */
function writeFakeClaude(binDir: string): string {
  const shim = path.join(binDir, 'claude');
  // Capture only the bridge credentials issued to this isolated child, never the user's environment.
  // The wrapper then runs the unchanged scripted CLI; it does not call a provider.
  const wrapper = path.join(binDir, 'fake-wrapper.mjs');
  writeFile(wrapper, `import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { spawn } from 'node:child_process';
const allowed = JSON.parse(readFileSync(${JSON.stringify(path.join(FIXTURE_DIR, 'fixture-agent-ids.json'))}, 'utf8'));
if (allowed.includes(process.env.CLUBHOUSE_AGENT_ID) && !process.argv.includes('--version') &&
    process.env.CLUBHOUSE_HOOK_NONCE && /^[0-9]+$/.test(process.env.CLUBHOUSE_MCP_PORT ?? '')) {
  const keys = ['CLUBHOUSE_AGENT_ID', 'CLUBHOUSE_MCP_PORT', 'CLUBHOUSE_HOOK_NONCE'];
  const file = ${JSON.stringify(FIXTURE_DIR)} + '/mcp-' + process.env.CLUBHOUSE_AGENT_ID + '.json';
  writeFileSync(file + '.pending', JSON.stringify(Object.fromEntries(keys.map(k => [k, process.env[k]]))), { mode: 0o600 });
  renameSync(file + '.pending', file);
}
const child = spawn(process.execPath, [${JSON.stringify(FAKE_CLAUDE)}, ...process.argv.slice(2)], { stdio: 'inherit' });
child.on('exit', code => process.exit(code ?? 1));
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => child.kill(signal));
`);
  writeFile(shim, `#!/bin/sh\nexec "${process.execPath}" "${wrapper}" "$@"\n`, 0o755);
  return shim;
}

/** A real paired controller used for wire evidence and HTTP-only refusal checks.
 * Bootstrap reads the certificate without sending secrets, compares the invitation's pin, then trusts only that
 * certificate. The observer uses a fresh session identity and is closed with the fixture.
 */
async function observeDesktop(status: any) {
  const pem = await new Promise<string>((resolve, reject) => {
    const socket = tls.connect({ host: '127.0.0.1', port: status.port, rejectUnauthorized: false }, () => {
      const cert = socket.getPeerCertificate();
      socket.end();
      if (cert.fingerprint256 !== status.tlsCertificateFingerprint) return reject(new Error('Observer certificate pin mismatch'));
      resolve(new crypto.X509Certificate(cert.raw).toString());
    });
    socket.on('error', reject);
  });
  const publicKey = crypto.generateKeyPairSync('ed25519').publicKey.export({ format: 'der', type: 'spki' });
  const fingerprint = crypto.createHash('sha256').update(publicKey).digest('hex').slice(0, 32).match(/.{2}/g)!.join(':');
  const keys = forge.pki.rsa.generateKeyPair(2048);
  const cert = forge.pki.createCertificate();
  cert.publicKey = keys.publicKey;
  cert.serialNumber = crypto.randomBytes(16).toString('hex');
  cert.validity.notBefore = new Date(Date.now() - 60_000);
  cert.validity.notAfter = new Date(Date.now() + 86_400_000);
  cert.setSubject([{ name: 'commonName', value: fingerprint }]);
  cert.setIssuer(cert.subject.attributes);
  cert.sign(keys.privateKey, forge.md.sha256.create());
  const options = { ca: pem, cert: forge.pki.certificateToPem(cert), key: forge.pki.privateKeyToPem(keys.privateKey),
    rejectUnauthorized: true, checkServerIdentity: () => undefined };
  const request = (method: string, route: string, body?: unknown): Promise<any> => new Promise((resolve, reject) => {
    const req = https.request({ host: '127.0.0.1', port: status.port, path: route, method, ...options,
      agent: false, headers: { 'Content-Type': 'application/json' } }, res => {
      let data = ''; res.on('data', d => data += d);
      res.on('end', () => resolve({ status: res.statusCode, body: data ? JSON.parse(data) : null }));
    });
    req.on('error', reject); req.setTimeout(20_000, () => req.destroy(new Error('Observer HTTP timeout')));
    req.end(body === undefined ? undefined : JSON.stringify(body));
  });
  expect((await request('POST', '/pair', { pin: status.pin, publicKey: publicKey.toString('base64'),
    alias: 'Live E2E wire observer', pairingMode: 'session' })).status).toBe(200);
  const caps = await request('GET', '/api/v1/mobile/capabilities');
  const frames: any[] = [];
  const ws = new WebSocket(`wss://127.0.0.1:${status.port}/ws`, options);
  ws.on('message', data => {
    const frame = JSON.parse(data.toString());
    // Persist only Dispatcher/catalog evidence and routed chat events; no pairing or transport credentials.
    if (frame.type === 'snapshot') {
      frames.push({ type: frame.type, seq: frame.seq, replayed: frame.replayed, payload: { dispatcher: frame.payload?.dispatcher } });
    } else if (frame.type === 'dispatcher:changed' || frame.type.startsWith('replay:')) {
      frames.push({ type: frame.type, seq: frame.seq, replayed: frame.replayed, payload: frame.payload });
    } else if (frame.type === 'chat:event' && frame.payload?.event?.type === 'user_message' && frame.payload.event.data?.source === 'mcp') {
      const event = frame.payload.event;
      frames.push({ type: frame.type, seq: frame.seq, payload: { agentId: frame.payload.agentId,
        event: { type: event.type, data: { source: event.data?.source, content: event.data?.content, routed: event.data?.routed } } } });
    }
  });
  await new Promise<void>((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  return { frames, ws, request, command: (fields: Record<string, unknown>) => request('POST', '/api/v1/mobile/commands',
    { version: 1, epoch: caps.body.epoch, commandId: crypto.randomUUID(), ...fields }) };
}

/** The real bridge, authenticated as the fixture's fake child (same approach as desktop e2e/dispatcher.spec.ts). */
async function callMcp(agentId: string, targetName: string, suffix: string, args: Record<string, unknown>,
                       allowed: Set<string>, desktopPid: number) {
  if (!allowed.has(agentId)) throw new Error('MCP refused: caller is not an agent created by this fixture');
  const file = path.join(FIXTURE_DIR, `mcp-${agentId}.json`);
  const env = JSON.parse(fs.readFileSync(file, 'utf8'));
  const port = Number(env.CLUBHOUSE_MCP_PORT);
  const guard = () => {
    if (!allowed.has(agentId) || env.CLUBHOUSE_AGENT_ID !== agentId || !env.CLUBHOUSE_HOOK_NONCE ||
        !Number.isInteger(port) || port <= 0 || port > 65535 || String(port) === process.env.E2E_FORBIDDEN_MCP_PORT) {
      throw new Error('MCP refused: invalid fixture credentials or inherited desktop port');
    }
    // No preload API exposes the bridge port. Require an actual listener owned by our launched Electron PID,
    // as well as rejecting the original inherited port. This check runs before EVERY RPC, including initialize.
    const listeners = execFileSync('/usr/sbin/lsof', ['-nP', '-a', '-p', String(desktopPid), '-iTCP', '-sTCP:LISTEN', '-Fn'], { encoding: 'utf8' });
    if (!listeners.split('\n').includes(`n127.0.0.1:${port}`)) {
      throw new Error('MCP refused: port is not bound by this fixture desktop');
    }
  };
  guard();
  log('MCP isolation verified: fixture-owned agent and desktop-owned listener; inherited port excluded');
  let session: string | null = null;
  let id = 0;
  const rpc = async (method: string, params = {}) => {
    guard();
    const response = await fetch(`http://127.0.0.1:${env.CLUBHOUSE_MCP_PORT}/mcp/${agentId}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Clubhouse-Nonce': env.CLUBHOUSE_HOOK_NONCE,
        ...(session ? { 'Mcp-Session-Id': session } : {}) },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }), signal: AbortSignal.timeout(20_000),
    });
    session = response.headers.get('mcp-session-id') ?? session;
    const body = await response.json() as any;
    if (body.error) throw new Error(`MCP ${method}: ${JSON.stringify(body.error)}`);
    return body.result;
  };
  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'phone-e2e', version: '1' } });
  const names = (await rpc('tools/list')).tools.map((t: any) => t.name) as string[];
  const name = names.find(n => targetName
    ? n.endsWith(`__${suffix}`) && n.toLowerCase().includes(targetName.toLowerCase()) : n === suffix);
  if (!name) throw new Error(`No ${suffix} for ${targetName}; tools: ${names.join(', ')}`);
  const result = await rpc('tools/call', { name, arguments: args });
  expect(result.isError, JSON.stringify(result.content)).not.toBe(true);
  return result;
}

test('Clubhouse Go live E2E desktop fixture', async () => {
  test.setTimeout(0);
  if (!FIXTURE_DIR) throw new Error('Set E2E_FIXTURE_DIR');
  const inherited = Object.keys(process.env).filter(key => key.startsWith('CLUBHOUSE_'));
  if (inherited.length) throw new Error(`Refusing to launch with inherited Clubhouse environment: ${inherited.join(', ')}`);
  log('Isolation preflight passed: no inherited CLUBHOUSE_* variables (agent identity, nonce and port absent)');
  const fixtureAgentIds = new Set<string>();
  const rememberAgents = (...ids: string[]) => {
    for (const id of ids) fixtureAgentIds.add(id);
    writeFile(path.join(FIXTURE_DIR, 'fixture-agent-ids.json'), JSON.stringify([...fixtureAgentIds]), 0o600);
  };
  rememberAgents();
  if (!fs.existsSync(FAKE_CLAUDE)) throw new Error(`This desktop ref has no ${FAKE_CLAUDE}`);
  const projectDir = path.join(FIXTURE_DIR, 'Phone Fixture');
  makeProject(projectDir);
  const claude = writeFakeClaude(path.join(FIXTURE_DIR, 'bin'));
  const missing = (cli: string) => path.join(FIXTURE_DIR, 'not-installed', cli);

  const { electronApp, window, userDataDir } = await launchApp({
    label: 'phone-e2e',
    args: ['--disable-gpu'],
    experimental: { chat: true, annex: true, dispatcher: true, newChrome: true },
    userDataFiles: {
      'mcp-settings.json': { enabled: true },
      'orchestrator-settings.json': { enabled: ['claude-code'], autoDetected: true },
      // The stream-json transport is what fake-claude.mjs speaks.
      'chat-runtime-settings.json': { 'claude-code': { mode: 'chat', driver: 'claude_stream_json' } },
    },
    env: {
      CLUBHOUSE_ANNEX_LOOPBACK_ONLY: '1',
      CLUBHOUSE_ANNEX_EPHEMERAL: '1',
      CLUBHOUSE_TEST_CLI_BINARIES: JSON.stringify({ 'claude-code': claude, 'codex-cli': missing('codex'), 'copilot-cli': missing('copilot') }),
      PATH: `${path.dirname(claude)}${path.delimiter}${process.env.PATH ?? ''}`,
    },
  });
  log(`launched pid ${electronApp.process().pid} with profile ${userDataDir}`);
  writeFile(path.join(FIXTURE_DIR, 'desktop.pid'), String(electronApp.process().pid));
  electronApp.process().stdout?.on('data', (d) => fs.appendFileSync(path.join(FIXTURE_DIR, 'desktop-stdout.log'), d));
  electronApp.process().stderr?.on('data', (d) => fs.appendFileSync(path.join(FIXTURE_DIR, 'desktop-stderr.log'), d));

  let observer: Awaited<ReturnType<typeof observeDesktop>> | undefined;
  try {
    const agents = await window.evaluate(async (projectPath) => {
      const ch = (window as any).clubhouse;
      await ch.project.add(projectPath);
      const echo = await ch.agent.createDurable(projectPath, 'Echo', 'emerald', undefined, false, 'claude-code');
      const builder = await ch.agent.createDurable(projectPath, 'Builder', 'blue', undefined, true, 'claude-code');
      return { echo: echo.id as string, builder: builder.id as string };
    }, projectDir);
    rememberAgents(agents.echo, agents.builder);
    log(`project and agents ready: ${JSON.stringify(agents)}`);

    await window.evaluate(async () => {
      const annex = (window as any).clubhouse.annex;
      const settings = await annex.getSettings();
      await annex.saveSettings({ ...settings, enableServer: true, deviceName: 'E2E Fixture Desktop', alias: 'E2E Fixture Desktop' });
    });

    // Phones pair over TLS only; wait until the TLS listener reports its certificate.
    let status: any;
    const deadline = Date.now() + 60_000;
    while (Date.now() < deadline) {
      status = await window.evaluate(() => (window as any).clubhouse.annex.getStatus());
      if (status?.tlsEnabled && status.port && status.pin && status.fingerprint && status.tlsCertificateFingerprint) break;
      await new Promise((r) => setTimeout(r, 500));
    }
    if (!status?.tlsCertificateFingerprint) throw new Error(`Annex did not start TLS: ${JSON.stringify({ ...status, pin: undefined })}`);
    if (status.advertising) throw new Error('A loopback-only fixture must not advertise');

    observer = await observeDesktop(status);
    const invitation = {
      host: '127.0.0.1',
      port: status.port,
      hostID: status.fingerprint,
      certificatePin: String(status.tlsCertificateFingerprint).replace(/:/g, '').toLowerCase(),
      pin: status.pin,
      name: 'E2E Fixture Desktop',
    };
    writeFile(path.join(FIXTURE_DIR, 'invitation.json'), JSON.stringify(invitation), 0o600);
    writeFile(path.join(FIXTURE_DIR, 'agents.json'), JSON.stringify({ project: path.basename(projectDir), ...agents }));
    log(`Annex listening on 127.0.0.1:${status.port}; invitation written`);

    const stop = path.join(FIXTURE_DIR, 'stop');
    const sleepRequest = path.join(FIXTURE_DIR, 'sleep-request');
    const sleepDone = path.join(FIXTURE_DIR, 'sleep-done');
    while (!fs.existsSync(stop)) {
      if (electronApp.process().exitCode !== null) throw new Error('The desktop exited while the phone tests ran');
      if (fs.existsSync(sleepRequest)) {
        const agentId = fs.readFileSync(sleepRequest, 'utf8').trim();
        fs.rmSync(sleepRequest, { force: true });
        fs.rmSync(sleepDone, { force: true });
        const result = await window.evaluate(async ({ id, projectPath }) => {
          try { await (window as any).clubhouse.agent.killAgent(id, projectPath, true); return 'ok'; }
          catch (err) { return `error: ${err instanceof Error ? err.message : String(err)}`; }
        }, { id: agentId, projectPath: projectDir });
        log(`slept ${agentId}: ${result}`);
        writeFile(sleepDone, `${agentId} ${result}\n`);
      }
      const requestFile = path.join(FIXTURE_DIR, 'dispatcher-request.json');
      if (fs.existsSync(requestFile)) {
        const request = JSON.parse(fs.readFileSync(requestFile, 'utf8'));
        fs.rmSync(requestFile);
        let result: unknown;
        try {
          switch (request.op) {
            case 'helper': {
              // Create a genuine helper through the real bridge, never by manufacturing a parent link on disk.
              const existing = await window.evaluate(async ({ projectPath, parentId }) => {
                const helpers = await (window as any).clubhouse.agent.listHelpers(projectPath, parentId);
                return helpers.find((h: any) => h.config.name === 'Relay-Fixture')?.config.id;
              }, { projectPath: projectDir, parentId: agents.echo });
              let helperId = existing;
              if (!helperId) {
                const started = await callMcp(agents.echo, '', 'start_helper', { name: 'Relay-Fixture', task: 'PHONE_HELPER_FIXTURE' },
                  fixtureAgentIds, electronApp.process().pid!);
                const body = JSON.parse(started.content[0].text);
                expect(body.state).toBe('starting');
                helperId = body.helperId;
              }
              rememberAgents(helperId);
              await expect.poll(async () => (await observer!.request('GET', `/api/v1/mobile/agents/${helperId}/settings`)).body?.state,
                { timeout: 60_000 }).toBe('running');
              result = { agentId: helperId }; break;
            }
            case 'phoneDisconnected':
              // The observer is the sole remaining WebSocket. Prove the phone disconnected before changing state.
              await expect.poll(async () => (await window.evaluate(() => (window as any).clubhouse.annex.getStatus())).connectedCount,
                { timeout: 20_000 }).toBe(1);
              result = 'ok'; break;
            case 'setEnabled': result = await window.evaluate(on => (window as any).clubhouse.dispatcher.setEnabled(on), request.enabled); break;
            case 'state': result = await window.evaluate(() => (window as any).clubhouse.dispatcher.get()); break;
            case 'policy': result = await window.evaluate(async ({ projectPath, agentId }) => {
              const ch = (window as any).clubhouse;
              const config = (await ch.agent.listDurable(projectPath)).find((a: any) => a.id === agentId);
              return { config, policy: await ch.agent.getOrchestrationPolicy(projectPath, agentId), bindings: await ch.mcpBinding.getBindings() };
            }, { projectPath: projectDir, agentId: request.agentId ?? agents.echo }); break;
            case 'command': result = await observer!.command(request.fields); break;
            case 'settings': result = await observer!.request('GET', `/api/v1/mobile/agents/${request.agentId}/settings`); break;
            case 'mcpEnabled': result = await window.evaluate(async enabled => {
              const ch = (window as any).clubhouse;
              await ch.settings.save('mcp', { ...await ch.settings.get('mcp'), enabled });
              return 'ok';
            }, request.enabled); break;
            case 'flag': result = await window.evaluate(async on => {
              const ch = (window as any).clubhouse;
              await ch.app.saveExperimentalSettings({ ...await ch.app.getExperimentalSettings(), dispatcher: on });
              return 'ok';
            }, request.enabled); break;
            case 'mcp': result = await callMcp(request.agentId, request.target, request.tool, request.args ?? {}, fixtureAgentIds, electronApp.process().pid!); break;
            case 'wire': {
              // Replay the actual server buffer, independently of the phone's UI catch-up assertion.
              const before = observer!.frames.length;
              observer!.ws.send(JSON.stringify({ type: 'mobile:replay', epoch: (await observer!.request('GET', '/api/v1/mobile/capabilities')).body.epoch, since: request.since ?? 0 }));
              await expect.poll(() => observer!.frames.slice(before).some(f => f.type === 'replay:end')).toBe(true);
              result = observer!.frames;
              writeFile(path.join(FIXTURE_DIR, 'dispatcher-wire.json'), evidence(result));
              break;
            }
            default: throw new Error(`Unknown fixture operation ${request.op}`);
          }
          if ((request.op === 'state' || request.op === 'setEnabled') && (result as any)?.agentId) rememberAgents((result as any).agentId);
          writeFile(path.join(FIXTURE_DIR, 'dispatcher-done.json'), evidence({ id: request.id, result }));
        } catch (err) {
          const error = err instanceof Error ? err.message : String(err);
          log(`Dispatcher fixture ${request.op} failed: ${evidence(error)}`);
          writeFile(path.join(FIXTURE_DIR, 'dispatcher-done.json'), evidence({ id: request.id, error }));
        }
      }
      await new Promise((r) => setTimeout(r, 500));
    }
    log('stop requested');
  } finally {
    observer?.ws.close();
    await electronApp.close().catch(() => {});
  }
});
