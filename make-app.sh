#!/bin/zsh
# Builds Toolbox.app (release) next to this script. Usage: ./make-app.sh [--open] [--debug-hooks]
# --debug-hooks compiles in the TOOLBOX_SNAPSHOT/TOOLBOX_DEBUG test hooks (App/Snapshot.swift); off by default.
set -euo pipefail
cd "$(dirname "$0")"

OPEN=0
FLAGS=()
for arg in "$@"; do
  case $arg in
    --open) OPEN=1 ;;
    --debug-hooks) FLAGS=(-Xswiftc -DTOOLBOX_DEBUG_HOOKS) ;;
    *) echo "usage: ./make-app.sh [--open] [--debug-hooks]" >&2; exit 2 ;;
  esac
done

swift build -c release --product Toolbox "${FLAGS[@]}"
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

if (( OPEN )); then
  pkill -x Toolbox || true
  open "$APP"
fi
