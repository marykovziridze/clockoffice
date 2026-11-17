# Privacy

ClockOffice runs on your Mac and has no server. It sends nothing to its author or to any third party, has no telemetry and needs no account.

## What it reads

- Claude Code's session files and transcripts in `~/.claude/`, to list your sessions and show their last messages.
- Codex's conversation files in `~/.codex/sessions/`, if there are any, for the same purpose. It writes nothing there, and Codex text never leaves your Mac: it is not given to the summary model.
- The list of running processes, to find which editor window hosts a session.

## What leaves your Mac

One thing, and only while "Summaries in plain words" is on (it is on by default): the last message of an idle Claude Code session is given to a small model through your own Claude Code (`claude -p`), under your own Anthropic account and plan, to decide whether it ends on a question and to write a one-line summary. Anthropic handles that text under the terms of your own account. Switch the setting off in the menu and nothing leaves your Mac.

## What it stores, and where

- `~/Library/Application Support/ClockOffice/`: `events.jsonl` (when each question appeared and how long it waited), `summaries.json`, screenshots you pasted into a reply, backups of `~/.claude/settings.json` made before the optional dialog hook is switched on, and `diagnostics.txt`.
- `~/.clockoffice/`: a random secret shared between the app and its editor extension, and the port each editor window listens on.
- `~/Library/Caches/ClockOffice/pictures`: copies of the pictures you pasted into a session, so the app can show them in the conversation. A picture not looked at for two weeks is cleared out.

Nothing is kept anywhere else. Delete those three folders to remove everything it stored.

## What it changes

- Only if you switch on "Show the words of Claude Code dialogs": two hook entries in `~/.claude/settings.json`, with a backup. Switching it off removes them.
- Only if you switch on "Show usage and model": it puts a small script in front of your status line command in `~/.claude/settings.json`, with a backup. The script hands Claude Code's status data (how much of your plan's limits is used, and the model) to the app on this Mac, then runs your own status line exactly as before. Switching it off puts your command back.
- Only if you choose "Set up replying in …": it installs its extension in that editor.
- Only if you press "Close session": after a four-second Undo it asks that session's Claude Code process to quit. It first checks that the process started when Claude Code's own record of the session says, so it cannot end another program.

## Links in a conversation

ClockOffice does not turn the text of a conversation into links: web addresses and file paths show as plain words. A picture shown under a message opens for viewing when you click it. Nothing a conversation names is ever run.

## Network

The app listens on `127.0.0.1` (this Mac only), port 47863, for its own widget and the optional hook. The editor extension listens on `127.0.0.1` too and answers only calls that carry the shared secret.
