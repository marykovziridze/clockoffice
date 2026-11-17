import * as fs from 'node:fs';
import * as path from 'node:path';
import * as crypto from 'node:crypto';

// The shared secret between ClockOffice and every editor window, kept in <home>/token (mode 0600).
// Several windows start at the same moment, so the file is created with "fail if it exists": exactly one window's
// value survives and all others read that one.
// (Found live: two windows each wrote their own value and one of them refused every call.)
export function readOrCreateToken(home: string): string {
  fs.mkdirSync(home, { recursive: true, mode: 0o700 });
  fs.chmodSync(home, 0o700);
  const file = path.join(home, 'token');
  try {
    fs.writeFileSync(file, crypto.randomBytes(24).toString('hex'), { mode: 0o600, flag: 'wx' });
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e;
  }
  fs.chmodSync(file, 0o600);
  return fs.readFileSync(file, 'utf8').trim();
}

// Read at every call, never kept in memory: a window that started with a stale or empty file heals itself.
// An empty file matches nothing.
export function currentToken(home: string): string | undefined {
  try {
    const t = fs.readFileSync(path.join(home, 'token'), 'utf8').trim();
    return t.length >= 32 ? t : undefined;
  } catch {
    return undefined;
  }
}
