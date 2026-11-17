import { execFileSync } from 'node:child_process';

// Parent map of every process, read once per lookup. `claude agents --json` reports the session's own pid, while
// VS Code knows only the shell it started; the session is that shell or one of its descendants.
export function parentMap(): Map<number, number> {
  const out = execFileSync('ps', ['-A', '-o', 'pid=,ppid='], { encoding: 'utf8' });
  const map = new Map<number, number>();
  for (const row of out.split('\n')) {
    const [pid, ppid] = row.trim().split(/\s+/).map(Number);
    if (pid) map.set(pid, ppid);
  }
  return map;
}

export function ancestry(pid: number, parents: Map<number, number>): number[] {
  const chain: number[] = [];
  let cur: number | undefined = pid;
  while (cur && cur > 1 && !chain.includes(cur)) {
    chain.push(cur);
    cur = parents.get(cur);
  }
  return chain;
}

// Text typed into a terminal reaches whatever reads its tty, so the target must be that reader: its stdin is the
// terminal's tty and it is in the tty's foreground process group. A background job of the same shell is refused.
export function readsTerminal(pid: number, shellPid: number): boolean {
  try {
    const tty = execFileSync('ps', ['-o', 'tty=', '-p', String(shellPid)], { encoding: 'utf8' }).trim();
    if (!tty || tty === '??') return false;
    const [pgid, tpgid] = execFileSync('ps', ['-o', 'pgid=,tpgid=', '-p', String(pid)], { encoding: 'utf8' }).trim().split(/\s+/).map(Number);
    if (!pgid || pgid !== tpgid) return false;
    const fd0 = execFileSync('lsof', ['-a', '-p', String(pid), '-d', '0', '-Fn'], { encoding: 'utf8' });
    return fd0.split('\n').some((l) => l === `n/dev/${tty}`);
  } catch {
    return false;
  }
}
