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
import { test } from '@playwright/test';
import { execFileSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
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
  writeFile(shim, `#!/bin/sh\nexec "${process.execPath}" "${FAKE_CLAUDE}" "$@"\n`, 0o755);
  return shim;
}

test('Clubhouse Go live E2E desktop fixture', async () => {
  test.setTimeout(0);
  if (!FIXTURE_DIR) throw new Error('Set E2E_FIXTURE_DIR');
  if (!fs.existsSync(FAKE_CLAUDE)) throw new Error(`This desktop ref has no ${FAKE_CLAUDE}`);
  const projectDir = path.join(FIXTURE_DIR, 'Phone Fixture');
  makeProject(projectDir);
  const claude = writeFakeClaude(path.join(FIXTURE_DIR, 'bin'));
  const missing = (cli: string) => path.join(FIXTURE_DIR, 'not-installed', cli);

  const { electronApp, window, userDataDir } = await launchApp({
    label: 'phone-e2e',
    args: ['--disable-gpu'],
    experimental: { chat: true, annex: true },
    userDataFiles: {
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

  try {
    const agents = await window.evaluate(async (projectPath) => {
      const ch = (window as any).clubhouse;
      await ch.project.add(projectPath);
      const echo = await ch.agent.createDurable(projectPath, 'Echo', 'emerald', undefined, false, 'claude-code');
      const builder = await ch.agent.createDurable(projectPath, 'Builder', 'blue', undefined, true, 'claude-code');
      return { echo: echo.id as string, builder: builder.id as string };
    }, projectDir);
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
      await new Promise((r) => setTimeout(r, 500));
    }
    log('stop requested');
  } finally {
    await electronApp.close().catch(() => {});
  }
});
