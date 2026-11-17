import * as assert from 'node:assert';
import { findByPid, validReply } from '../../src/match';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { currentToken, readOrCreateToken } from '../../src/handshake';

describe('findByPid', () => {
  it('returns the terminal with the exact pid', () => {
    assert.strictEqual(findByPid([{ terminal: 'A', pid: 1 }, { terminal: 'B', pid: 2 }], 2), 'B');
  });
  it('returns nothing when no pid matches, never a fallback', () => {
    assert.strictEqual(findByPid([{ terminal: 'A', pid: 1 }], 9), undefined);
  });
  it('returns nothing when two terminals claim the same pid', () => {
    assert.strictEqual(findByPid([{ terminal: 'A', pid: 3 }, { terminal: 'B', pid: 3 }], 3), undefined);
  });
});

describe('validReply', () => {
  it('accepts plain replies', () => {
    for (const t of ['continue', 'yes', '1', 'merge', 'a', 'Wait for my look', 'ja, graag']) assert.ok(validReply(t), t);
  });
  it('refuses every control or format character and a leading "!"', () => {
    for (const t of ['', 'a\nb', 'yes\r', '\u0003', '\u001b[A', 'x\u009b', 'x\u0085', 'x\u2028', 'x\u2029', 'x\u200b', 'x\u202e', '!ls', '  !ls', 'yes \\', 'ok\\', '﹗ls', '/exit', '/logout', ' /compact', '# remember this', '！ls', '／exit', 'x'.repeat(2001)])
      assert.strictEqual(validReply(t), false, JSON.stringify(t));
  });
});

describe('replies the prompt would read as a command', () => {
  it('refuses a leading @ & ? in plain and fullwidth forms, and allows them anywhere else', () => {
    for (const bad of ['@README.md look', '&x', '?', '  ?help', '＠file', '＆x', '？']) assert.strictEqual(validReply(bad), false, bad);
    for (const good of ['is it ok? yes & no @ home', 'yes']) assert.strictEqual(validReply(good), true, good);
  });
});

describe('one token for every editor window', () => {
  it('the first window creates it; every later window reads the same one and never overwrites it', () => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ao-token-'));
    const a = readOrCreateToken(home);
    const b = readOrCreateToken(home);
    assert.strictEqual(a, b);
    assert.strictEqual(a.length, 48);
    assert.strictEqual(fs.statSync(path.join(home, 'token')).mode & 0o777, 0o600);
    // A window that lost the start-up race finds the winner's token already there.
    fs.writeFileSync(path.join(home, 'token'), 'f'.repeat(48));
    assert.strictEqual(readOrCreateToken(home), 'f'.repeat(48));
  });
  it('the token is read fresh at every call; a missing or short file matches nothing', () => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ao-token-'));
    assert.strictEqual(currentToken(home), undefined);
    fs.writeFileSync(path.join(home, 'token'), '');
    assert.strictEqual(currentToken(home), undefined);
    fs.writeFileSync(path.join(home, 'token'), 'a'.repeat(48) + '\n');
    assert.strictEqual(currentToken(home), 'a'.repeat(48));
    fs.writeFileSync(path.join(home, 'token'), 'b'.repeat(48));
    assert.strictEqual(currentToken(home), 'b'.repeat(48));
  });
});
