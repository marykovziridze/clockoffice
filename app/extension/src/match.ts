// Picks the terminal that owns the target pid: its shell is the pid itself or one of the pid's ancestors.
// Never falls back to the active terminal: a reply typed into the wrong session is worse than no reply.
export interface PidTerminal<T> { terminal: T; pid: number | undefined }

export function findByPid<T>(candidates: PidTerminal<T>[], pid: number, chain: number[] = [pid]): T | undefined {
  for (const p of chain) {
    const hits = candidates.filter((c) => c.pid === p);
    if (hits.length === 1) return hits[0].terminal;
    if (hits.length > 1) return undefined;
  }
  return undefined;
}

// A reply is printable text only: no control or format characters of any kind (C0, C1, line and paragraph
// separators, zero-width marks), and it may not start with "!" (shell command), "/" (slash command such as /exit,
// after which the next line would reach the shell), "#" (memory note), "@" (file picker), "&" or "?" (help),
// fullwidth forms included. The extension adds the one Enter itself.
export function validReply(text: unknown): text is string {
  return typeof text === 'string' && text.length > 0 && text.length <= 2000 &&
    !/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(text) && !/^[\s\u3000]*[!/#@&?！／＃﹗﹟∕＠＆？]/u.test(text) && !/\\\s*$/.test(text); // a trailing \ makes Enter insert a new line in Claude Code instead of sending
}
