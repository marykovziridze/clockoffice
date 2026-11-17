#!/bin/bash
# Builds "ClockOffice.app" (menu-bar app + desktop widget) with the command-line Swift tools; no Xcode needed.
#   scripts/build.sh            build into mac/build/
#   scripts/build.sh --install  also copy to ~/Applications and (re)start it
# Signing. macOS ties a permission the user gave (for example "access files in your Desktop folder") to the app's
# signature. An ad-hoc signature changes with every build, so each rebuild asked again; a certificate keeps it.
# Which signature, first that applies:
#   CLOCKOFFICE_SIGN="<certificate name or SHA-1>"     for one build
#   ~/.config/clockoffice/sign holding the same          for every build on this Mac (never in the repository)
#   ad-hoc ("-"): works, but a permission is asked again after each rebuild
# A certificate is never picked from the keychain on its own: codesign may then stop on a keychain password dialog,
# and the keychain can hold certificates of a team that is not yours.
#
# A private look: when Resources/look/look.json is there, its pictures replace the dial and the build gets an
# identity of its own (a name on disk, an ID, a link scheme, a port), so it can sit beside the standard app.
set -euo pipefail
cd "$(dirname "$0")/.."
SIGN="${CLOCKOFFICE_SIGN:-}"
if [ -z "$SIGN" ] && [ -s "$HOME/.config/clockoffice/sign" ]; then SIGN="$(head -n 1 "$HOME/.config/clockoffice/sign")"; fi
if [ "${SIGN:--}" = "-" ]; then
  echo "note: signing ad-hoc, so macOS asks again for permissions after each rebuild. To keep them, put the SHA-1 of your own certificate in ~/.config/clockoffice/sign (see: security find-identity -v -p codesigning)." >&2
fi
SIGN="${SIGN:--}"
VERSION="0.1.0"
LOOK="Resources/look"
# The file is checked by the same rules the app reads it by (Edition.read): a look that is only half understood
# would give an app with its own ID that answers on the standard app's port, or the other way round.
if [ -f "$LOOK/look.json" ]; then
  /usr/bin/python3 - "$LOOK" <<'PY' || { echo "refused: fix Resources/look/look.json, or remove the folder to build the standard app." >&2; exit 1; }
import json, os, re, sys
look = sys.argv[1]
def once(pairs):
    keys = [k for k, _ in pairs]
    twice = sorted({k for k in keys if keys.count(k) > 1})
    if twice: raise ValueError("written twice: " + ", ".join(twice))
    return dict(pairs)
try:
    o = json.load(open(os.path.join(look, "look.json"), encoding="utf-8"), object_pairs_hook=once)
    if not isinstance(o, dict): raise ValueError("not an object")
except Exception as e:
    sys.exit("look.json cannot be read: %s" % e)
problems = []
s = o.get("suffix")
if not (isinstance(s, str) and re.fullmatch(r"[a-z0-9]{1,24}", s)): problems.append('"suffix" must be 1 to 24 lower-case letters or digits')
p = o.get("port")
if not (isinstance(p, int) and not isinstance(p, bool) and 1024 < p < 65536 and p != 47863): problems.append('"port" must be a whole number between 1025 and 65535, and not 47863 (the standard app)')
a = o.get("appFile")
if not (isinstance(a, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,40}", a) and a != "ClockOffice"): problems.append('"appFile" must be a plain file name other than "ClockOffice"')
old = o.get("oldRelays", [])
if not (isinstance(old, list) and all(isinstance(n, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,40}-statusline\.sh", n) for n in old)): problems.append('"oldRelays" must be a list of file names ending in -statusline.sh')
for k in ("accentDark", "accentLight"):
    if k in o and not (isinstance(o[k], str) and re.fullmatch(r"[0-9A-Fa-f]{6}", o[k])): problems.append('"%s" must be six hex digits' % k)
icon = o.get("icon", "")
if not (isinstance(icon, str) and re.fullmatch(r"[A-Za-z0-9._-]+", icon) and os.path.isfile(os.path.join(look, icon + ".png"))): problems.append('"icon" must name a .png file in the look folder')
for f in ("mark.png", "spin.png", "menu-glyph.svg"):
    if not os.path.isfile(os.path.join(look, f)): problems.append("the look folder has no " + f)
if problems: sys.exit("look.json: " + "; ".join(problems))
# What goes into the app is this reading written out again, not the file as typed: the app and this script read
# JSON with different programs, and a file they read differently gave a bundle with one ID and another port.
os.makedirs("build", exist_ok=True)
kept = {k: o[k] for k in ("suffix", "port", "appFile", "icon", "accentDark", "accentLight", "oldRelays") if k in o}
open("build/look.json", "w", encoding="utf-8").write(json.JSONEncoder(indent=1).encode(kept) + "\n")
PY
fi
look() { [ -f "$LOOK/look.json" ] && /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' build/look.json "$1" || true; }
SUFFIX="$(look suffix)"
APPFILE="$(look appFile)"; APPFILE="${APPFILE:-ClockOffice}"
ICON="$(look icon)"; ICON="${ICON:-icon-clock}"
ICONFILE="Resources/$ICON.png"; [ -f "$LOOK/$ICON.png" ] && ICONFILE="$LOOK/$ICON.png"
ID="io.github.marykovziridze.clockoffice${SUFFIX:+.$SUFFIX}"
SCHEME="clockoffice${SUFFIX:+-$SUFFIX}"
APP="build/$APPFILE.app"
APPEX="$APP/Contents/PlugIns/ClockOfficeWidget.appex"

swift build -c release 2>&1 | tail -3
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp "$BIN/ClockOffice" "$APP/Contents/MacOS/ClockOffice"
cp "$BIN/ClockOfficeWidget" "$APPEX/Contents/MacOS/ClockOfficeWidget"
cp Resources/menu-glyph.svg "$APP/Contents/Resources/"
if [ -f "$LOOK/look.json" ]; then
  # The look's own files, over the standard ones; the widget needs the picture and the settings too.
  cp build/look.json "$LOOK/mark.png" "$LOOK/spin.png" "$LOOK/menu-glyph.svg" "$APP/Contents/Resources/"
  cp build/look.json "$LOOK/mark.png" "$APPEX/Contents/Resources/"
fi
[ -f build/clockoffice-terminal.vsix ] && cp build/clockoffice-terminal.vsix "$APP/Contents/Resources/" || echo "note: no editor extension in build/ (run scripts/build-extension.sh first); replying in place will not be offered"

# App icon from the chosen artwork.
SET="build/AppIcon.iconset"; rm -rf "$SET"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONFILE" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONFILE" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/$ICON.icns"   # named after the artwork: a new icon is a new file, so no stale cache

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ClockOffice</string>
  <key>CFBundleDisplayName</key><string>ClockOffice</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>ClockOffice</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>$ICON</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>ClockOfficeCommit</key><string>$(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet HEAD -- . ../app/extension 2>/dev/null || echo +changes)</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licence.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$ID</string>
    <key>CFBundleURLSchemes</key><array><string>$SCHEME</string></array>
  </dict></array>
</dict></plist>
PLIST

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ClockOfficeWidget</string>
  <key>CFBundleDisplayName</key><string>ClockOffice</string>
  <key>CFBundleIdentifier</key><string>$ID.widget</string>
  <key>CFBundleExecutable</key><string>ClockOfficeWidget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST

# The widget must run in Apple's sandbox; it only needs to reach the app on 127.0.0.1.
cat > build/widget.entitlements <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST

codesign --force --sign "$SIGN" --entitlements build/widget.entitlements "$APPEX"
codesign --force --sign "$SIGN" "$APP"
codesign --verify --deep --strict "$APP" && echo "built and signed: $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/$APPFILE.app"
  mkdir -p "$HOME/Applications"
  # Only the installed copy: a test rig runs the same program from a build folder, and stopping every copy by
  # name would stop that too.
  pkill -f "^$DEST/Contents/MacOS/ClockOffice" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "^$DEST/Contents/MacOS/ClockOffice" >/dev/null || break; sleep 0.3; done
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  open "$DEST" || { sleep 2; open "$DEST"; }   # the first try can fail while macOS still tidies up the old copy
  echo "installed and started: $DEST"
fi
