#!/bin/bash
# Compiles the editor extension and packs it as mac/build/clockoffice-terminal.vsix (bundled into the app by build.sh).
set -euo pipefail
cd "$(dirname "$0")/../../app"
[ -d node_modules ] || npm ci --no-audit --no-fund
rm -rf extension/out
npx tsc -p extension/tsconfig.json
mkdir -p ../mac/build
(cd extension && npx --yes @vscode/vsce@3.9.2 package --no-dependencies --allow-missing-repository -o ../../mac/build/clockoffice-terminal.vsix)
