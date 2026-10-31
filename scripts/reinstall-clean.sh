#!/bin/zsh
# Luoto — a fork of Atoll (DynamicIsland)
# Copyright (C) 2026 amidamaru940 and Luoto contributors
# Licensed under the GNU General Public License v3.0 or later; see LICENSE.
#
# Builds Luoto from this checkout and, only when the build succeeds, removes
# every trace of the installed Luoto (apps, settings, data,
# caches, permissions, helper processes) and installs the new build in
# /Applications. A failed build deletes nothing.
#
# Usage: scripts/reinstall-clean.sh   (to update and keep everything: scripts/install.sh)
# Signed with Config/Local.xcconfig's identity when there is one, ad-hoc otherwise.

set -uo pipefail
cd "$(dirname "$0")/.."

DERIVED="build/DerivedData-reinstall"
LOG="build/reinstall-build.log"
APP="$DERIVED/Build/Products/Release/Luoto.app"
DOMAINS=(io.github.amidamaru940.luoto io.github.amidamaru940.luoto.dev)
mkdir -p build
rm -rf "$DERIVED"

echo "1/4 Сборка (первый раз 3–7 минут: скачиваются пакеты)…"
if ! xcodebuild build -project DynamicIsland.xcodeproj -scheme DynamicIsland -configuration Release \
    -destination "platform=macOS,arch=arm64" -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual >"$LOG" 2>&1; then
  echo "✗ Сборка не прошла. Ничего не удалено. Вывод сборки:"
  grep -E "error:" "$LOG" | sort -u | head -40
  grep -qiE "license|runFirstLaunch" "$LOG" && echo "→ Сначала: sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch"
  grep -qiE "MetalToolchain|metal toolchain" "$LOG" && echo "→ Сначала: xcodebuild -downloadComponent MetalToolchain"
  echo "Полный журнал: $PWD/$LOG"
  exit 1
fi
[[ -d "$APP" ]] || { echo "✗ Сборка не нашлась ($APP). Ничего не удалено."; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "✗ Подпись не проверилась. Ничего не удалено."; exit 1; }
echo "✓ Собрано"

echo "2/4 Закрываю старые версии…"
for name in Luoto; do
  osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1 || true
done
sleep 2
pkill -x Luoto 2>/dev/null || true
# Helper processes the old versions may have left behind.
pkill -f "mediaremote-adapter.pl" 2>/dev/null || true
pkill -f "com.apple.mobiletimer.logging" 2>/dev/null || true
pkill -f "LsnM" 2>/dev/null || true

echo "3/4 Удаляю всё старое…"
for app in "/Applications/Luoto.app"; do
  [[ -e "$app" ]] || continue
  rm -rf "$app" 2>/dev/null || sudo rm -rf "$app"
done
for domain in "${DOMAINS[@]}"; do
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -rf ~/Library/Preferences/"$domain".plist \
         ~/Library/Application\ Support/"$domain" \
         ~/Library/Caches/"$domain" \
         ~/Library/HTTPStorages/"$domain" ~/Library/HTTPStorages/"$domain".binarycookies \
         ~/Library/Saved\ Application\ State/"$domain".savedState
  tccutil reset All "$domain" >/dev/null 2>&1 || true
done
rm -rf "${TMPDIR:-/tmp}/Luoto clipboard screenshots"

echo "4/4 Ставлю новую…"
ditto "$APP" /Applications/Luoto.app
xattr -dr com.apple.quarantine /Applications/Luoto.app 2>/dev/null || true
open /Applications/Luoto.app
echo "✓ Готово: новая Luoto в /Applications и запущена."
echo "  Настройки с нуля: пройди короткое знакомство и дай Универсальный доступ, когда спросит."
echo "  Запуск при входе включи заново в настройках, если он нужен."
