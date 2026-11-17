#!/bin/bash
# Builds ClockOffice on this Mac, copies it to ~/Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")"

# `command -v swift` cannot be the test: every Mac has /usr/bin/swift, a stand-in that only offers to install the
# tools. xcode-select -p names the folder of the tools (or of Xcode) when they are installed.
tools="$(xcode-select -p 2>/dev/null || true)"
if [ -z "$tools" ] || [ ! -d "$tools" ]; then
  echo "ClockOffice needs Apple's command-line tools. Run:  xcode-select --install"
  echo "When that has finished, run ./install.sh again."
  exit 1
fi

if command -v npm >/dev/null 2>&1; then
  mac/scripts/build-extension.sh
else
  echo "note: Node.js was not found, so the editor extension is not built."
  echo "      You will see every question and can open its window, but not reply from the app."
  echo "      Install Node.js and run ./install.sh again to add replying."
fi

mac/scripts/build.sh --install
