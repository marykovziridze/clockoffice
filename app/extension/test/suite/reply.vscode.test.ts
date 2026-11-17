import * as assert from 'node:assert';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as vscode from 'vscode';

// Runs inside an isolated VS Code (own user-data-dir and extensions-dir). Each terminal runs zsh, which starts the
// fake session as a child process, the same shape as Claude Code started from a VS Code terminal.

const logs = process.env.CLOCKOFFICE_TEST_LOGS!;
const node = process.env.CLOCKOFFICE_NODE!;
const fake = path.resolve(__dirname, '../../../../fake-session/fake-session.cjs');
const tokenValue = () => fs.readFileSync(path.join(process.env.CLOCKOFFICE_HOME!, 'token'), 'utf8').trim();

type Ev = { event: string; pid?: number; ppid?: number; hex?: string; line?: string };
const read = (log: string): Ev[] =>
  fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function until<T>(fn: () => T | undefined, ms = 15_000): Promise<T> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = fn();
    if (v) return v;
    await sleep(100);
  }
  throw new Error('timed out');
}

async function session(name: string, background?: string) {
  const log = path.join(logs, `${name}.jsonl`);
  const bg = background ? `'${node}' '${fake}' '${path.join(logs, `${background}.jsonl`)}' & ` : '';
  const terminal = vscode.window.createTerminal({
    name,
    shellPath: '/bin/zsh',
    shellArgs: ['-f', '-c', `${bg}'${node}' '${fake}' '${log}'; echo exited`],
  });
  const ready = await until(() => read(log).find((e) => e.event === 'ready'));
  const shellPid = await terminal.processId;
  return { terminal, log, pid: ready.pid!, ppid: ready.ppid!, shellPid };
}

// The bridge announces its real port; the runner holds the base port with a decoy, so this must differ from it.
function bridgePort(): number {
  const dir = path.join(process.env.CLOCKOFFICE_HOME!, 'bridges');
  const files = fs.readdirSync(dir);
  assert.strictEqual(files.length, 1);
  return JSON.parse(fs.readFileSync(path.join(dir, files[0]), 'utf8')).port;
}

async function post(route: string, body: object, token = tokenValue()) {
  const r = await fetch(`http://127.0.0.1:${bridgePort()}${route}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-clockoffice-token': token },
    body: JSON.stringify(body),
  });
  return r.status;
}

const suiteStarted = Date.now();

suite('reply into the exact terminal', () => {
  let a: Awaited<ReturnType<typeof session>>;
  let b: Awaited<ReturnType<typeof session>>;

  suiteSetup(async () => {
    a = await session('A');
    b = await session('B');
    await sleep(500);
  });

  test('the extension writes only into the /tmp sandbox, never ~/.clockoffice', () => {
    assert.ok(String(process.env.CLOCKOFFICE_HOME).startsWith('/tmp/ao-'), String(process.env.CLOCKOFFICE_HOME));
    assert.ok(fs.existsSync(path.join(process.env.CLOCKOFFICE_HOME!, 'token')));
    // The real folder exists once the extension is installed in the user's own editor, so the check
    // is that this run left it alone: no bridge announced there for this test window, and the token not rewritten.
    const real = path.join(require('node:os').homedir(), '.clockoffice');
    assert.strictEqual(fs.existsSync(path.join(real, 'bridges', `${process.pid}.json`)), false);
    const realToken = path.join(real, 'token');
    if (fs.existsSync(realToken)) assert.ok(fs.statSync(realToken).mtimeMs < suiteStarted, 'the real token was rewritten during the test run');
  });

  test('the fake session is a child of the terminal shell, not the shell itself', () => {
    assert.notStrictEqual(b.pid, b.shellPid);
    assert.strictEqual(b.ppid, b.shellPid);
  });

  test('B receives "continue" plus Enter; A receives nothing', async () => {
    assert.strictEqual(await post('/reply', { pid: b.pid, text: 'continue' }), 200);
    const submit = await until(() => read(b.log).find((e) => e.event === 'submit'));
    assert.strictEqual(submit.line, 'continue');
    await sleep(500);
    assert.deepStrictEqual(read(a.log).filter((e) => e.event !== 'ready'), []);
  });

  test('reveal brings B forward', async () => {
    a.terminal.show(false);
    await until(() => vscode.window.activeTerminal === a.terminal);
    assert.strictEqual(await post('/reveal', { pid: b.pid }), 200);
    await until(() => vscode.window.activeTerminal === b.terminal, 5000);
  });

  test('/has finds B without typing or switching terminals, names the open folder, and refuses strangers', async () => {
    a.terminal.show(false);
    await until(() => vscode.window.activeTerminal === a.terminal);
    const before = [read(a.log).length, read(b.log).length];
    const r = await fetch(`http://127.0.0.1:${bridgePort()}/has`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-clockoffice-token': tokenValue() },
      body: JSON.stringify({ pid: b.pid }),
    });
    assert.strictEqual(r.status, 200);
    const body = (await r.json()) as { ok: boolean; folder?: string };
    assert.strictEqual(body.ok, true);
    assert.strictEqual(body.folder, vscode.workspace.workspaceFolders?.[0]?.uri.fsPath);
    assert.strictEqual(await post('/has', { pid: 999999 }), 404);
    assert.strictEqual(await post('/has', { pid: b.pid }, 'wrong'), 403);
    await sleep(300);
    assert.strictEqual(vscode.window.activeTerminal, a.terminal);
    assert.deepStrictEqual([read(a.log).length, read(b.log).length], before);
  });

  test('a token replaced on disk takes effect at once: the old one is refused, the new one accepted', async () => {
    const file = path.join(process.env.CLOCKOFFICE_HOME!, 'token');
    const old = fs.readFileSync(file, 'utf8').trim();
    const fresh = 'c'.repeat(48);
    fs.writeFileSync(file, fresh);
    try {
      assert.strictEqual(await post('/has', { pid: b.pid }, old), 403);
      assert.strictEqual(await post('/has', { pid: b.pid }, fresh), 200);
    } finally {
      fs.writeFileSync(file, old);
    }
    assert.strictEqual(await post('/has', { pid: b.pid }, old), 200);
  });

  test('refuses an unknown pid, a wrong token and control characters, and types nothing', async () => {
    const before = [read(a.log).length, read(b.log).length];
    assert.strictEqual(await post('/reply', { pid: 999999, text: 'yes' }), 404);
    assert.strictEqual(await post('/reply', { pid: b.pid, text: 'yes' }, 'wrong'), 403);
    assert.strictEqual(await post('/reply', { pid: b.pid, text: 'yes\u0003' }), 400);
    assert.strictEqual(await post('/reply', { pid: b.pid, text: 'a\nb' }), 400);
    await sleep(500);
    assert.deepStrictEqual([read(a.log).length, read(b.log).length], before);
  });

  test('the bridge moved off the busy base port', () => {
    assert.notStrictEqual(bridgePort(), Number(process.env.CLOCKOFFICE_PORT));
  });

  test('refuses C1 controls, line separators, zero-width marks and a leading "!"', async () => {
    const before = read(b.log).length;
    for (const text of ['yes\u009b2J', 'yes\u0085', 'yes\u2028', 'y\u200bes', '!rm -rf x', ' !ls']) {
      assert.strictEqual(await post('/reply', { pid: b.pid, text }), 400, JSON.stringify(text));
    }
    await sleep(300);
    assert.strictEqual(read(b.log).length, before);
  });

  test('two replies at once arrive as two separate submits, never merged', async () => {
    const statuses = await Promise.all([post('/reply', { pid: b.pid, text: 'yes' }), post('/reply', { pid: b.pid, text: 'no' })]);
    assert.deepStrictEqual(statuses, [200, 200]);
    await until(() => read(b.log).filter((e) => e.event === 'submit').length >= 3 || undefined);
    const lines = read(b.log).filter((e) => e.event === 'submit').map((e) => e.line).slice(1).sort();
    assert.deepStrictEqual(lines, ['no', 'yes']);
  });

  test('a background job of the same shell is refused, and the foreground session gets nothing', async () => {
    const d = await session('D', 'D-bg');
    const bgLog = path.join(logs, 'D-bg.jsonl');
    const bg = await until(() => read(bgLog).find((e) => e.event === 'ready'));
    assert.strictEqual(bg.ppid, d.shellPid);
    assert.strictEqual(await post('/reply', { pid: bg.pid!, text: 'continue' }), 404);
    await sleep(500);
    assert.deepStrictEqual(read(d.log).filter((e) => e.event !== 'ready'), []);
    assert.strictEqual(await post('/reply', { pid: d.pid, text: 'ok' }), 200);
    // With a second process on the shell the tty can stay in cooked mode (Enter arrives as LF), so this test checks
    // routing only: the foreground session got "ok" and a line end, the background job got nothing.
    const hex = await until(() => {
      const h = read(d.log).filter((e) => e.event === 'bytes').map((e) => e.hex).join('');
      return /^6f6b(0d|0a)$/.test(h) ? h : undefined;
    }).catch(() => { throw new Error(`D log: ${JSON.stringify(read(d.log))}`); });
    assert.ok(hex);
    assert.deepStrictEqual(read(bgLog).filter((e) => e.event !== 'ready'), []);
  });

  test('a reply queued behind one that ends the session is not typed into the shell', async () => {
    const e = await session('E');
    const statuses = await Promise.all([post('/reply', { pid: e.pid, text: 'quit' }), post('/reply', { pid: e.pid, text: 'yes' })]);
    assert.deepStrictEqual(statuses, [200, 404]);
    await sleep(500);
    assert.deepStrictEqual(read(e.log).filter((x) => x.event === 'submit').map((x) => x.line), ['quit']);
  });

  test('records whether sendText(text, true) alone submits in a bracketed-paste TUI', async () => {
    const c = await session('C');
    c.terminal.sendText('yes', true);
    await sleep(2000);
    const events = read(c.log);
    const submitted = events.some((e) => e.event === 'submit' && e.line === 'yes');
    const bytes = events.filter((e) => e.event === 'bytes').map((e) => e.hex).join(' ');
    const finding = { sendTextWithNewlineSubmits: submitted, bytesHex: bytes, vscode: vscode.version };
    fs.writeFileSync(path.join(logs, 'sendtext-finding.json'), JSON.stringify(finding, null, 2));
    console.log('[finding] sendText(text, true):', JSON.stringify(finding));
    assert.ok(bytes.length > 0, 'terminal C received bytes');
  });
});
