import * as vscode from 'vscode';
import * as http from 'node:http';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { findByPid, validReply } from './match';
import { ancestry, parentMap, readsTerminal } from './procs';
import { currentToken, readOrCreateToken } from './handshake';

// Bridge between ClockOffice (the menu-bar app) and the terminals of this editor window. Works in VS Code and its
// forks (Antigravity, Cursor, Windsurf, VSCodium): they share the same terminal API. Listens on 127.0.0.1 only and requires the token
// stored (mode 0600) in CLOCKOFFICE_HOME. Each VS Code window runs its own bridge and announces its real port in
// CLOCKOFFICE_HOME/bridges/<pid>.json, so the board never posts to a port some other program took.

const home = process.env.CLOCKOFFICE_HOME || path.join(os.homedir(), '.clockoffice');
const basePort = Number(process.env.CLOCKOFFICE_PORT || 47821);

async function terminalFor(pid: number): Promise<vscode.Terminal | undefined> {
  const candidates = await Promise.all(
    vscode.window.terminals.map(async (terminal) => ({ terminal, pid: await terminal.processId })),
  );
  const t = findByPid(candidates, pid, ancestry(pid, parentMap()));
  const shell = t && candidates.find((c) => c.terminal === t)?.pid;
  return t && shell && readsTerminal(pid, shell) ? t : undefined;
}

// One reply at a time per terminal, so two clicks never interleave into "yesno".
const queues = new WeakMap<vscode.Terminal, Promise<unknown>>();

export async function reply(pid: number, text: string): Promise<boolean> {
  if (!validReply(text)) return false;
  const t = await terminalFor(pid);
  if (!t) return false;
  let typed = false;
  const run = (queues.get(t) ?? Promise.resolve()).then(async () => {
    // Checked again at the moment of typing: an earlier reply in the queue may have ended the session, and then
    // the shell would be the one reading the terminal.
    if ((await terminalFor(pid)) !== t) return;
    typed = true;
    // Text and Enter go separately; the extension suite records whether sendText(text, true) alone would do.
    t.sendText(text, false);
    await new Promise((r) => setTimeout(r, 60));
    t.sendText('\r', false);
    await new Promise((r) => setTimeout(r, 60));
  });
  queues.set(t, run.catch(() => undefined));
  await run;
  return typed;
}

export async function reveal(pid: number): Promise<boolean> {
  const t = await terminalFor(pid);
  if (!t) return false;
  t.show(false);
  return true;
}

// The folder (or workspace file) open in this window. ClockOffice opens it with the editor to bring exactly
// this window to the front; the extension itself cannot raise a window.
function folder(): string | undefined {
  const ws = vscode.workspace.workspaceFile;
  if (ws && ws.scheme === 'file') return ws.fsPath;
  return vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
}

function listen(server: http.Server, port: number, tries: number): Promise<number> {
  return new Promise((resolve, reject) => {
    const onError = (e: NodeJS.ErrnoException) => {
      server.off('listening', onListening);
      if (e.code === 'EADDRINUSE' && tries > 1) resolve(listen(server, port + 1, tries - 1));
      else reject(e);
    };
    const onListening = () => { server.off('error', onError); resolve(port); };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, '127.0.0.1');
  });
}

export async function activate(context: vscode.ExtensionContext) {
  readOrCreateToken(home);
  const server = http.createServer((req, res) => {
    const done = (code: number, body: object) => {
      res.writeHead(code, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    const secret = currentToken(home);
    if (req.method !== 'POST' || !secret || req.headers['x-clockoffice-token'] !== secret) return done(403, { ok: false });
    let raw = '';
    req.on('data', (c) => { raw += c; if (raw.length > 8192) req.destroy(); });
    req.on('end', async () => {
      try {
        const body = JSON.parse(raw);
        const pid = Number(body.pid);
        if (!Number.isInteger(pid) || pid <= 1) return done(400, { ok: false, error: 'pid' });
        if (req.url === '/reply') {
          if (!validReply(body.text)) return done(400, { ok: false, error: 'text' });
          const ok = await reply(pid, body.text);
          return done(ok ? 200 : 404, { ok });
        }
        if (req.url === '/reveal') {
          const ok = await reveal(pid);
          return done(ok ? 200 : 404, ok ? { ok, folder: folder() } : { ok });
        }
        // Asks only: does a terminal of this window belong to that session? Types nothing, shows nothing.
        if (req.url === '/has') {
          const ok = !!(await terminalFor(pid));
          return done(ok ? 200 : 404, ok ? { ok, folder: folder() } : { ok });
        }
        done(404, { ok: false });
      } catch {
        done(400, { ok: false });
      }
    });
  });

  const bridges = path.join(home, 'bridges');
  const announce = path.join(bridges, `${process.pid}.json`);
  try {
    const port = await listen(server, basePort, 20);
    fs.mkdirSync(bridges, { recursive: true, mode: 0o700 });
    fs.writeFileSync(announce, JSON.stringify({ port, pid: process.pid, app: vscode.env.appName }), { mode: 0o600 });
  } catch (e) {
    vscode.window.showWarningMessage(`ClockOffice cannot reply from this window: ${(e as Error).message}`);
  }
  context.subscriptions.push({ dispose: () => { server.close(); fs.rmSync(announce, { force: true }); } });
}

export function deactivate() {}
