#!/bin/zsh
# Builds Toolbox.app (release) next to this script. Usage: ./make-app.sh [--open]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Toolbox
BIN="$(swift build -c release --show-bin-path)/Toolbox"

APP=Toolbox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Toolbox"
cp Support/Info.plist "$APP/Contents/Info.plist"

ICONS=.build/icon
if [[ ! -f $ICONS/AppIcon.icns || Support/make-icon.swift -nt $ICONS/AppIcon.icns ]]; then
  mkdir -p $ICONS
  swift Support/make-icon.swift $ICONS
  iconutil -c icns $ICONS/AppIcon.iconset -o $ICONS/AppIcon.icns
fi
cp $ICONS/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--open" ]]; then
  pkill -x Toolbox || true
  open "$APP"
fi
