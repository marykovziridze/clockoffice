#!/usr/bin/env node
// Stand-in for an interactive Claude Code session. Like the real TUI it puts the terminal in raw mode and turns on
// bracketed paste, prints a question, and records every byte it receives. A line counts as submitted only when a
// carriage return arrives outside a bracketed paste, which is what makes the real TUI act on a reply.
// Usage: node fake-session.cjs <logFile> [question]
const fs = require('node:fs');

const log = process.argv[2];
const question = process.argv[3] || 'Shall I continue?';
const append = (o) => fs.appendFileSync(log, JSON.stringify({ t: Date.now(), ...o }) + '\n');

append({ event: 'ready', pid: process.pid, ppid: process.ppid });
if (process.stdin.isTTY) process.stdin.setRawMode(true);
process.stdout.write('\x1b[?2004h');
process.stdout.write(`${question}\r\n> `);

let line = '';
let inPaste = false;
// Without a terminal (sandbox), the parent holds stdin: when it goes away, so does this session.
if (!process.stdin.isTTY) process.stdin.on('end', () => process.exit(0));
process.stdin.on('data', (buf) => {
  let s = buf.toString('utf8');
  append({ event: 'bytes', hex: buf.toString('hex') });
  while (s.length) {
    if (s.startsWith('\x1b[200~')) { inPaste = true; s = s.slice(6); continue; }
    if (s.startsWith('\x1b[201~')) { inPaste = false; s = s.slice(6); continue; }
    const ch = s[0];
    s = s.slice(1);
    if (ch === '\x03') { append({ event: 'interrupt' }); process.exit(0); }
    if (ch === '\r' && !inPaste) {
      append({ event: 'submit', line });
      if (line === 'quit') process.exit(0); // like /exit: the session ends and the shell takes the terminal
      process.stdout.write(`\r\n(received: ${line})\r\n> `);
      line = '';
      continue;
    }
    line += ch;
  }
});
