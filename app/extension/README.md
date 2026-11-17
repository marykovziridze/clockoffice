# ClockOffice terminal bridge

Lets the ClockOffice menu-bar app type your reply into the exact terminal of a coding session, and bring that
terminal forward. Works in VS Code and its forks (Antigravity, Cursor, Windsurf, VSCodium).

- Listens on this Mac only (127.0.0.1), and only answers calls that carry the token in `~/.clockoffice/token`.
- Types only into the terminal whose foreground program is the session itself. Never the active terminal as a fallback.
- Refuses control characters and replies that start with `/`, `!` or `#`.

Install it from the ClockOffice menu (right-click the icon in the menu bar → "Set up replying in …"), or by hand:
`code --install-extension clockoffice-terminal.vsix`. Remove it with `code --uninstall-extension clockoffice.clockoffice-terminal`.
