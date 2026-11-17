// Extension suite: pure logic under mocha, then the reply test in an isolated VS Code downloaded by
// @vscode/test-electron (its own user-data-dir and extensions-dir; the user's own VS Code is never touched). Everything
// the extension writes goes to CLOCKOFFICE_HOME in the /tmp sandbox. (Overriding HOME for the extension host made
// VS Code 1.142.0 hang before activation, measured 2026-10-19 23:47.)
// The VS Code run opens a window on the desktop, so it runs once per change of the files it tests: a pass is
// recorded under the hash of those files and reused. CLOCKOFFICE_VSCODE=skip skips it and says so
// (for other tasks); CLOCKOFFICE_VSCODE=force always runs it.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { runTests } from '@vscode/test-electron';

const here = path.dirname(fileURLToPath(import.meta.url));
const ext = path.join(here, '..');
const app = path.join(ext, '..');
const out = path.join(ext, 'out', 'test', 'suite');

const unit = spawnSync('npx', ['mocha', path.join(out, '*.unit.test.js')], { stdio: 'inherit' });
if (unit.status !== 0) process.exit(unit.status ?? 1);

// A short temp folder: VS Code opens a socket inside --user-data-dir and macOS caps socket paths at 103 characters,
// so a sandbox inside a deep checkout breaks the run.
const mode = process.env.CLOCKOFFICE_VSCODE || 'auto';
const shared = path.join('/tmp', 'clockoffice-vscode');
const hash = crypto.createHash('sha256');
for (const f of [...walk(path.join(ext, 'src')), ...walk(path.join(ext, 'test')), path.join(app, 'fake-session', 'fake-session.cjs'), path.join(ext, 'package.json')].sort())
  hash.update(f.slice(app.length)).update(fs.readFileSync(f));
const stamp = path.join(shared, 'passes', hash.digest('hex').slice(0, 16));
function walk(d) {
  return fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
}
if (mode === 'skip') {
  console.log('SKIPPED the isolated VS Code reply test (CLOCKOFFICE_VSCODE=skip). Not a pass.');
  process.exit(3); // test-all reports this suite as SKIP, never PASS
}
if (mode !== 'force' && fs.existsSync(stamp)) {
  console.log(`isolated VS Code reply test: reusing the pass recorded ${fs.readFileSync(stamp, 'utf8').trim()} for these exact sources (${path.basename(stamp)}); CLOCKOFFICE_VSCODE=force reruns it`);
  process.exit(0);
}

fs.mkdirSync(path.join(shared, 'cache'), { recursive: true });
const box = fs.mkdtempSync(path.join(process.platform === 'darwin' ? '/tmp' : os.tmpdir(), 'ao-'));
const dirs = Object.fromEntries(['user', 'extensions', 'workspace', 'home', 'logs'].map((d) => [d, path.join(box, d)]));
for (const d of Object.values(dirs)) fs.mkdirSync(d, { recursive: true });

// A decoy holds the base port, as another program might. The bridge must move to the next port and announce it;
// the decoy must never receive a request (which would leak the token).
const basePort = 47900 + (process.pid % 90);
let decoyHits = 0;
const decoy = http.createServer((req, res) => { decoyHits++; res.end('{"ok":true}'); });
await new Promise((r) => decoy.listen(basePort, '127.0.0.1', r));

// Watchdog: a test VS Code that has not finished in 3 minutes is killed and the suite fails, so a stuck window
// never hangs the run (23:21 and 23:32 runs hung). Every process started from the sandbox folder is killed.
const killBox = () => { spawnSync('pkill', ['-9', '-f', box]); spawnSync('pkill', ['-9', '-f', path.join(shared, 'cache')]); };
const watchdog = setTimeout(() => {
  console.error('extension suite: VS Code did not finish within 3 minutes; killing it');
  killBox();
  process.exit(1);
}, 180_000);

try {
  await runTests({
    version: process.env.CLOCKOFFICE_VSCODE_VERSION || 'stable',
    cachePath: path.join(shared, 'cache'),
    extensionDevelopmentPath: ext,
    extensionTestsPath: path.join(out, 'index.js'),
    launchArgs: [dirs.workspace, '--user-data-dir', dirs.user, '--extensions-dir', dirs.extensions,
      '--disable-extensions', '--disable-workspace-trust', '--skip-welcome', '--skip-release-notes'],
    extensionTestsEnv: {
      CLOCKOFFICE_HOME: path.join(dirs.home, '.clockoffice'),
      CLOCKOFFICE_PORT: String(basePort),
      CLOCKOFFICE_TEST_LOGS: dirs.logs,
      CLOCKOFFICE_NODE: process.execPath,
    },
  });
  const finding = path.join(dirs.logs, 'sendtext-finding.json');
  if (fs.existsSync(finding)) console.log('sendText finding:', fs.readFileSync(finding, 'utf8'));
  if (decoyHits) throw new Error(`the decoy on the base port received ${decoyHits} request(s)`);
  fs.mkdirSync(path.dirname(stamp), { recursive: true });
  fs.writeFileSync(stamp, new Date().toISOString());
} catch (e) {
  console.error('extension suite failed:', e.message);
  process.exitCode = 1;
} finally {
  clearTimeout(watchdog);
  killBox();
  decoy.close();
  fs.rmSync(box, { recursive: true, force: true });
}
