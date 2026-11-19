#!/bin/bash
# Builds ClockOffice on this Mac, copies it to ~/Applications and starts it.
#   ./install.sh           check this Mac, then build and install (about a minute and a half)
#   ./install.sh --remove  take ClockOffice out again, settings first, then everything it stored
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/ClockOffice.app"
ID="io.github.marykovziridze.clockoffice"
EXT="clockoffice.clockoffice-terminal"
SUPPORT="$HOME/Library/Application Support/ClockOffice"

# The editors whose extension list ClockOffice may be in (VS Code and its forks), by their command-line tool.
editor_clis() {
  # CLOCKOFFICE_EDITOR_ROOTS: where to look instead (for testing the script without touching real editors).
  for root in ${CLOCKOFFICE_EDITOR_ROOTS:-/Applications "$HOME/Applications"}; do
    for app in "Visual Studio Code" "Visual Studio Code - Insiders" "Antigravity" "Cursor" "Windsurf" "VSCodium"; do
      for tool in code cursor windsurf codium antigravity; do
        bin="$root/$app.app/Contents/Resources/app/bin/$tool"
        if [ -x "$bin" ]; then echo "$bin"; break; fi
      done
    done
  done
}

if [ "${1:-}" = "--remove" ]; then
  echo "Removing ClockOffice."
  osascript -e "tell application id \"$ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
  # Settings first: with the app's folder gone, a status line still pointing at its relay script would show an
  # error in Claude Code instead of your own line. The app takes its own entries out and backs the file up.
  if [ -x "$APP/Contents/MacOS/ClockOffice" ]; then
    # An app built before --remove-settings existed would start as the menu-bar app instead of answering.
    if ! grep -aq -- "--remove-settings" "$APP/Contents/MacOS/ClockOffice"; then
      echo "The ClockOffice in ~/Applications is older than this folder and cannot take its settings out itself, so nothing was deleted."
      echo "Run ./install.sh first (it updates the app), then ./install.sh --remove."
      exit 1
    fi
    if ! "$APP/Contents/MacOS/ClockOffice" --remove-settings; then
      echo "ClockOffice could not take its entries out of ~/.claude/settings.json (see above), so nothing was deleted."
      echo "Fix what the line above names in ~/.claude/settings.json, then run ./install.sh --remove again."
      exit 1
    fi
  fi
  # Then, with or without the app, one last look at the file's text before anything is deleted: nothing may still
  # name this app's folder (the status line relay) or its port (the hooks), whatever form it was edited into.
  # (A private build's entries name another folder and port and are not this app's.)
  # grep exits 0 for a match, 1 for none, 2 when it cannot read the file. 2 counts as "no file" only when there
  # truly is none: not a link, and a ~/.claude that is either truly missing or can be opened (followed if a link).
  S="$HOME/.claude/settings.json"
  # The relay's own name is matched too, in any case and any byte encoding: a hand-written path may spell the
  # folder "Application\ Support" or "~/Library/…" (verifier 6).
  pattern() { LC_ALL=C grep -aqi -e "Application Support/ClockOffice/" -e "ClockOffice/clockoffice-statusline" -e "127.0.0.1:47863/" "$@"; }
  found=0; pattern "$S" 2>/dev/null || found=$?
  # JSON may spell "/" as "\/" or a letter as "\u0041" (Apple's own tools write "\/"), which the text never matches:
  # the file is also read as JSON, with the JavaScript that ships with macOS, and that reading checked too.
  if [ "$found" -eq 1 ]; then
    decoded="$(/usr/bin/osascript -l JavaScript -e 'function run(a) {
      var s = $.NSString.stringWithContentsOfFileEncodingError(a[0], 4, null);
      // Not UTF-8 (a stray byte from an editor in another encoding): read it as Latin-1, which always reads, and the
      // patterns are plain ASCII. A failed read is a nil object here, which "!s" does not catch.
      if (!s || s.isNil()) s = $.NSString.stringWithContentsOfFileEncodingError(a[0], 5, null);
      if (!s || s.isNil()) return ""; try { return JSON.stringify(JSON.parse(s.js)) } catch (e) { return "" } }' "$S" 2>/dev/null || true)"
    if [ -n "$decoded" ] && printf '%s' "$decoded" | pattern; then found=0; fi
  fi
  if [ "$found" -eq 2 ] && [ ! -e "$S" ] && [ ! -L "$S" ] \
     && { { [ ! -e "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ]; } || [ -x "$HOME/.claude" ]; }; then found=1; fi
  if [ "$found" -eq 0 ] && [ -x "$APP/Contents/MacOS/ClockOffice" ]; then
    echo "~/.claude/settings.json still names ClockOffice (its folder or port 47863) in a form the app did not write, so nothing was deleted."
    echo "Take that part out of the file by hand, then run ./install.sh --remove again."
    exit 1
  elif [ "$found" -eq 0 ]; then
    echo "The app is already gone but ~/.claude/settings.json still names ClockOffice, so nothing was deleted."
    echo "Install it again (./install.sh), then run ./install.sh --remove: the app takes its own entries out first."
    exit 1
  elif [ "$found" -ne 1 ]; then
    echo "~/.claude/settings.json cannot be read, so it is not known whether ClockOffice's entries are in it. Nothing was deleted."
    echo "Make the file (and the ~/.claude folder) readable for your user, then run ./install.sh --remove again."
    exit 1
  fi
  editor_clis | while read -r cli; do
    editor="$(printf '%s' "$cli" | sed 's|.*/\([^/]*\)\.app/.*|\1|')"
    if "$cli" --uninstall-extension "$EXT" >/dev/null 2>&1; then echo "editor extension removed from $editor"; fi
  done
  rm -rf "$APP" "$SUPPORT" "$HOME/.clockoffice" "$HOME/Library/Caches/ClockOffice"
  # What macOS keeps for the app under its ID: its preferences, web cache and the widget's container.
  defaults delete "$ID" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Preferences/$ID.plist" "$HOME/Library/HTTPStorages/$ID" "$HOME/Library/Caches/$ID" 2>/dev/null || true
  rm -rf "$HOME/Library/Containers/$ID.widget" 2>/dev/null || true
  echo "Removed: the app, $SUPPORT, ~/.clockoffice, ~/Library/Caches/ClockOffice and what macOS kept for it under $ID."
  if [ -d "$SUPPORT settings backup" ]; then echo "Kept: a backup of your ~/.claude/settings.json in \"$SUPPORT settings backup\"."; fi
  echo "Done."
  exit 0
fi

if [ -n "${1:-}" ]; then echo "Unknown option: $1. Use ./install.sh to install, or ./install.sh --remove to take it out."; exit 1; fi

# Check this Mac before building, and say what is missing in one place.
problems=0
macos="$(sw_vers -productVersion)"
if [ "${macos%%.*}" -lt 14 ]; then echo "ClockOffice needs macOS 14 or later; this Mac has $macos."; problems=1; fi
# `command -v swift` cannot be the test: every Mac has /usr/bin/swift, a stand-in that only offers to install the
# tools. xcode-select -p names the folder of the tools (or of Xcode) when they are installed.
tools="$(xcode-select -p 2>/dev/null || true)"
if [ -z "$tools" ] || [ ! -d "$tools" ]; then
  echo "ClockOffice needs Apple's command-line tools. Run:  xcode-select --install"
  problems=1
fi
if ! command -v claude >/dev/null 2>&1 && [ ! -d "$HOME/.claude" ]; then
  echo "Claude Code was not found on this Mac. ClockOffice shows its sessions, so install Claude Code first."
  problems=1
fi
if [ "$problems" -ne 0 ]; then echo "When that is done, run ./install.sh again."; exit 1; fi

echo "This builds ClockOffice from the source in this folder ($(uname -m), macOS $macos) and puts it in ~/Applications."
echo "It changes nothing in ~/.claude. Two optional features in its menu do, and say so before they do."
echo "To take it out again later: ./install.sh --remove"
echo "Building takes about a minute and a half."
echo

if command -v npm >/dev/null 2>&1; then
  mac/scripts/build-extension.sh
else
  echo "note: Node.js was not found, so the editor extension is not built."
  echo "      You will see every question and can open its window, but not reply from the app."
  echo "      Install Node.js and run ./install.sh again to add replying."
fi

mac/scripts/build.sh --install
echo
echo "Next: click the icon in your menu bar. A session waiting for you shows at the top of the list."
