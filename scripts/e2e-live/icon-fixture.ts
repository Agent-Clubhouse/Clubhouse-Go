/** Passive capture on this fixture's real TLS server. No response or frame is manufactured or changed. */
import * as fs from 'fs';
import * as path from 'path';
import type { ElectronApp } from '../launch';
import type { Page } from '@playwright/test';

export async function createIconFixture(electronApp: ElectronApp, window: Page, userDataDir: string,
                                        projectPath: string, agentId: string) {
  const images = JSON.parse(fs.readFileSync(path.join(__dirname, 'live-icon-images.json'), 'utf8'));
  await electronApp.evaluate(async ({ app }) => {
    // Playwright evaluates in a VM without a dynamic-import callback. Use Node's builtin loader.
    const https = process.getBuiltinModule('https') as typeof import('node:https');
    const crypto = process.getBuiltinModule('crypto') as typeof import('node:crypto');
    const root = globalThis as any;
    root.__phoneIconAudit = { connects: [], snapshots: [], downloads: [], errors: [] };
    const audit = root.__phoneIconAudit;
    const prototype = https.Server.prototype as any;
    const emit = prototype.emit;
    prototype.emit = function (event: string, ...args: any[]) {
      const request = args[0];
      if (event === 'upgrade' && request?.url?.startsWith('/ws')) {
        const url = new URL(request.url, 'https://fixture.invalid');
        if (url.searchParams.get('client') === 'mobile') {
          audit.connects.push({ mobile: true, iconRefs: url.searchParams.get('iconRefs') === '1' });
          const socket = args[1], write = socket.write;
          let buffered = Buffer.alloc(0), handshake = false;
          socket.write = function (...parts: any[]) {
            try {
              const bytes = typeof parts[0] === 'string' ? Buffer.from(parts[0]) : Buffer.from(parts[0]);
              buffered = Buffer.concat([buffered, bytes]);
              if (!handshake) {
                const end = buffered.indexOf('\r\n\r\n');
                if (end >= 0) { buffered = buffered.subarray(end + 4); handshake = true; }
              }
              while (handshake && buffered.length >= 2) {
                const opcode = buffered[0] & 15;
                let count = buffered[1] & 127, offset = 2;
                if (count === 126) { if (buffered.length < 4) break; count = buffered.readUInt16BE(2); offset = 4; }
                else if (count === 127) { if (buffered.length < 10) break; count = Number(buffered.readBigUInt64BE(2)); offset = 10; }
                if (count > 1024 * 1024 || buffered[1] & 128) throw new Error('Unexpected fixture WebSocket encoding');
                if (buffered.length < offset + count) break;
                const body = buffered.subarray(offset, offset + count); buffered = buffered.subarray(offset + count);
                if (opcode === 1) {
                  const frame = JSON.parse(body.toString());
                  if (frame.type === 'snapshot') audit.snapshots.push({ seq: frame.payload?.lastSeq,
                    refs: frame.payload?.iconRefs ?? null, agentIcons: frame.payload?.agentIcons,
                    projectIcons: frame.payload?.projectIcons, dispatcherId: frame.payload?.dispatcher?.agent?.id });
                }
              }
            } catch (error) { audit.errors.push(String(error)); buffered = Buffer.alloc(0); }
            return write.apply(this, parts);
          };
        }
      }
      if (event === 'request' && request?.url?.startsWith('/api/v1/icons/')) {
        const response = args[1], chunks: Buffer[] = [];
        let bytes = 0;
        const collect = (chunk: any) => {
          if (chunk == null) return;
          const data = typeof chunk === 'string' ? Buffer.from(chunk) : Buffer.from(chunk);
          bytes += data.length; if (bytes <= 73728) chunks.push(data);
        };
        const write = response.write, end = response.end;
        response.write = function (...parts: any[]) { collect(parts[0]); return write.apply(this, parts); };
        response.end = function (...parts: any[]) { collect(parts[0]); return end.apply(this, parts); };
        response.once('finish', () => {
          const url = new URL(request.url, 'https://fixture.invalid');
          const pieces = url.pathname.split('/');
          audit.downloads.push({ kind: pieces[4], id: decodeURIComponent(pieces[5]), version: url.searchParams.get('v'),
            status: response.statusCode, bytes, type: response.getHeader('content-type'), etag: response.getHeader('etag'),
            sha: crypto.createHash('sha256').update(Buffer.concat(chunks)).digest('hex') });
        });
      }
      return emit.call(this, event, ...args);
    };
    return app.getPath('home');
  }).then(home => {
    if (fs.realpathSync(home) !== fs.realpathSync(userDataDir)) throw new Error('Icon fixture home escaped its profile');
  });
  const seed = await window.evaluate(async ({ projectPath, agentId, image }) => {
    const ch = (window as any).clubhouse;
    const project = (await ch.project.list()).find((p: any) => p.path === projectPath);
    if (!project) throw new Error('Fixture project missing');
    await ch.agent.updateDurable(projectPath, agentId, { color: 'gray', emoji: null });
    await ch.project.update(project.id, { color: 'gray', emoji: null });
    const agentFile = await ch.agent.saveIcon(projectPath, agentId, image);
    const projectFile = await ch.project.saveCroppedIcon(project.id, image);
    const dispatcher = await ch.dispatcher.setEnabled(true);
    await ch.agent.saveIcon(dispatcher.path, dispatcher.agentId, image);
    return { agentFile, projectFile, projectId: project.id, dispatcherId: dispatcher.agentId };
  }, { projectPath, agentId, image: 'data:image/png;base64,' + images.redPNG.base64 });
  const files = [path.join(userDataDir, '.clubhouse-dev', 'agent-icons', seed.agentFile),
                 path.join(userDataDir, '.clubhouse-dev', 'project-icons', seed.projectFile)];
  for (const file of files) {
    if (!fs.realpathSync(file).startsWith(fs.realpathSync(userDataDir) + path.sep)) throw new Error('Icon path escaped fixture');
  }
  let current = 'redPNG', flip = false;
  const descriptor = (name: string) => {
    const { base64, ...metadata } = images[name]; return metadata;
  };
  const snapshot = async () => {
    flip = !flip;
    await window.evaluate(async ({ projectId, color }) => (window as any).clubhouse.project.update(projectId, { color }),
      { projectId: seed.projectId, color: flip ? 'indigo' : 'gray' });
  };
  return {
    async state() {
      return { ...await electronApp.evaluate(() => (globalThis as any).__phoneIconAudit),
        ...seed, agentId, current, expected: descriptor(current), dispatcherExpected: descriptor('redPNG') };
    },
    async change(name: string, broadcast: boolean) {
      if (!images[name]) throw new Error('Unknown icon fixture');
      for (const file of files) fs.writeFileSync(file, Buffer.from(images[name].base64, 'base64'));
      current = name;
      if (broadcast) await snapshot();
      return descriptor(name);
    },
    snapshot,
    async remove() {
      await window.evaluate(async ({ projectPath, agentId, projectId }) => {
        const ch = (window as any).clubhouse;
        await ch.agent.removeIcon(projectPath, agentId);
        await ch.project.update(projectId, { icon: null, color: 'gray' });
      }, { projectPath, agentId, projectId: seed.projectId });
      current = 'redPNG';
    },
  };
}
