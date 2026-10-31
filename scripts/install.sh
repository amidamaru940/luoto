#!/bin/zsh
# Luoto — a fork of Atoll (DynamicIsland)
# Copyright (C) 2026 amidamaru940 and Luoto contributors
# Licensed under the GNU General Public License v3.0 or later; see LICENSE.
#
# Updates the installed Luoto from this checkout and keeps everything else:
# settings, clipboard history, screenshot batches, permissions. Builds
# Release; only when the build succeeds is /Applications/Luoto.app replaced.
#
# Signing: with Config/Local.xcconfig (an Apple Development identity) macOS
# recognises every new build as the same app and keeps its permissions.
# Without it the build is ad-hoc and macOS asks for each permission again.
#
# Usage: scripts/install.sh            (scripts/reinstall-clean.sh wipes all)

set -uo pipefail
cd "$(dirname "$0")/.."

DERIVED="build/DerivedData"
LOG="build/install-build.log"
APP="$DERIVED/Build/Products/Release/Luoto.app"
mkdir -p build

echo "1/3 Сборка…"
if ! xcodebuild build -project DynamicIsland.xcodeproj -scheme DynamicIsland -configuration Release \
    -destination "platform=macOS,arch=arm64" -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual >"$LOG" 2>&1; then
  echo "✗ Сборка не прошла, установленная Luoto не тронута:"
  grep -E "error:" "$LOG" | sort -u | head -30
  echo "Полный журнал: $PWD/$LOG"
  exit 1
fi
codesign --verify --deep --strict "$APP" || { echo "✗ Подпись не проверилась, ничего не заменено."; exit 1; }
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "  подпись ad-hoc: macOS спросит разрешения заново (Config/Local.xcconfig это исправляет)"
else
  echo "  подпись: $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
fi

echo "2/3 Закрываю Luoto…"
osascript -e 'tell application "Luoto" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x Luoto >/dev/null || break; sleep 1; done
pkill -x Luoto 2>/dev/null || true
pkill -f "Luoto.app/Contents/Resources/mediaremote-adapter.pl" 2>/dev/null || true

echo "3/3 Ставлю и запускаю…"
rm -rf /Applications/Luoto.app.previous
[[ -e /Applications/Luoto.app ]] && mv /Applications/Luoto.app /Applications/Luoto.app.previous
if ditto "$APP" /Applications/Luoto.app; then
  rm -rf /Applications/Luoto.app.previous
else
  echo "✗ Не удалось скопировать, возвращаю прежнюю версию."
  rm -rf /Applications/Luoto.app
  [[ -e /Applications/Luoto.app.previous ]] && mv /Applications/Luoto.app.previous /Applications/Luoto.app
  exit 1
fi
open /Applications/Luoto.app
echo "✓ Готово: $(defaults read /Applications/Luoto.app/Contents/Info.plist CFBundleShortVersionString), $(git rev-parse --short HEAD), настройки и данные на месте."
