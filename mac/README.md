# ClockOffice for macOS

A small Mac app in the menu bar that shows which coding sessions have a question for you, lets you answer from there,
and takes you to the right window. Plus a desktop widget and a full window.

## What it shows
- **Yellow ring, the hand goes round**: the session is working. **Orange ring with a soft shine that breathes**:
  it needs you, for a question or a permission. **Green ring, still**: finished. **Red ring, still**: the plan's
  limit is used up and the session waits for the reset (only with "Show usage and model" on).
- The number in the menu bar is the count of sessions that need you.
- The dropdown lists questions (longest wait first) with the question as the headline, one-click answers where the
  question offers them, and a reply box; below them the sessions that are working or finished. Click a session for
  its conversation and a message box.

## Where the facts come from
1. Claude Code's own session registry (`~/.claude/sessions/<pid>.json`, the data behind `claude agents --json`):
   busy / waiting / idle, per session, whichever app it runs in. A session Claude Code marks "waiting" is always shown
   as a question.
2. For an idle session only: its last message. A small model (through your own Claude Code, inside your plan, about
   2,000 tokens per message) decides whether it ends on a question and writes the headline and "In short".
   Switch it off in the menu ("Summaries in plain words") and wording rules do the job instead.
3. Optional: the words of a Claude Code *dialog* (a question with choices, a permission prompt) exist only inside its
   window until answered. "Show the words of Claude Code dialogs" in the menu adds two hook entries to
   `~/.claude/settings.json` (backup kept) so Claude Code hands them to the app. Off by default.

## Acting on a session
- **Reply in place** needs the ClockOffice extension in the editor that hosts the session (VS Code and forks:
  Antigravity, Cursor, Windsurf, VSCodium). Right-click the icon in the menu bar → "Set up replying in …". It types your text plus
  one Enter into that session's own terminal, never the active terminal. Without it you get "Show in …" (the
  session's own window) and "Open in Claude" (the session in the Claude app or on claude.ai, when Remote Control is on).
- **Files and screenshots**: use the + in the message box or paste a screenshot (⌘V); in the window you can also drop a file on
  the message box. They are sent as file paths the session reads itself.
- **Keyboard**, the same in the dropdown and the window: ↑ ↓ move through the sessions · Return opens the selected one
  (or sends what is typed) · Esc goes back, then closes · ⌘1…⌘9 pick a question's answer · ⌘O opens the session's
  window · ⌘W closes the dropdown. Hold ⌘ to see the numbers next to the answers.
- **Show in …** brings the session's editor window forward (and its exact terminal tab with the extension).
- **Close session** under the message box asks that one Claude Code session to quit, after four seconds in which
  you can undo. The conversation is kept and can be resumed.
- A reply is refused if the session changed since you saw it (another status, a later moment, a newer message or
  dialog), or if it starts with a character Claude Code reads as a command: `/` `!` `#` `@` `&` `?`.

## Build
No Xcode needed, only the command-line tools (`xcode-select --install`).

    mac/scripts/build-extension.sh     # the editor extension → mac/build/clockoffice-terminal.vsix
    mac/scripts/build.sh --install     # the app → ~/Applications/ClockOffice.app, then starts it
    cd mac && swift test               # logic tests
    cd app && npm install && npm run test:ext   # extension tests, in an isolated copy of VS Code
    "…/ClockOffice.app/Contents/MacOS/ClockOffice" --render /tmp/shots   # every surface as PNG, with sample sessions

`CLOCKOFFICE_SIGN="Apple Development: …"` signs with a certificate instead of ad-hoc.

A build can carry a look of its own: a folder `Resources/look` with a picture for the mark (`mark.png`, and
`spin.png` for it turning), a menu-bar glyph, an icon and a small settings file `look.json` (a name part, a port,
two accent colours). Such a build gets its own name, ID and port, so it runs beside the standard one. Without the
folder you get the dial described above.

## Adding the widget
Right-click the desktop → Edit Widgets → search "ClockOffice" → drag the large or medium one out.
macOS decides how often a widget may refresh, so it says "as of 10:42". For the live picture, trust the menu bar.

## What it does not do yet
- Other tools: the app is built around one adapter per tool (`SessionSource` in
  `Sources/ClockOfficeCore/Models.swift`). Claude Code is complete. Codex conversations are listed and read, never
  answered from the app. Nothing else exists.
- Replying into Terminal.app or iTerm: only "Show in …" (it brings that terminal's window forward) and "Open in
  Claude" there.
- Typing a free-text answer into a dialog; dialogs take their numbered choices only.
- Notifications.

## Files it keeps
- `~/Library/Application Support/ClockOffice/`: `events.jsonl` (when each question appeared and how long it waited:
  the number this app exists to shrink), `summaries.json`, pasted screenshots, backups of Claude Code's settings
  from before each change the app made to them, the status line relay script, `diagnostics.txt`.
- `~/Library/Caches/ClockOffice/`: pictures pasted into conversations, written out so they can be shown.
- `~/.clockoffice/`: the secret shared with the editor extension.
- In `~/.claude/settings.json`, only while the menu item is on: two hook entries ("Show the words of Claude Code
  dialogs") and the relay in front of your status line command ("Show usage and model").

## Remove it
In this order, because the first step needs the app:
1. In the app's menu (right-click the icon in the menu bar) switch off "Show usage and model" and "Show the words
   of Claude Code dialogs", and "Open at login" if it is on. That takes the app's entries out of `~/.claude/settings.json` again
   (the file is rewritten with its keys in alphabetical order); a copy from before each change is in
   `~/Library/Application Support/ClockOffice/settings-backups/`.
2. Quit from the same menu and delete `~/Applications/ClockOffice.app`. Remove the desktop widget if you added it.
3. Uninstall the extension in every editor where you set up replying: in its Extensions panel find "ClockOffice",
   then Uninstall. For VS Code the command is `code --uninstall-extension clockoffice.clockoffice-terminal`.
4. Delete the three folders listed under "Files it keeps".

If the app is already gone and your Claude Code status line shows "No such file or directory": open
`~/.claude/settings.json`. `statusLine.command` reads `'<path to the relay script>' '<your own command>'`; with two
builds of the app installed there are two such scripts, one inside the other. Replace the whole value with your own
command, or delete the `statusLine` entry if you had none.
