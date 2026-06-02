#!/usr/bin/env bash
#
# Полная сборка релизного DMG для Glagol с красивой install-сценой:
#   1. Clean Release build (arm64 only — Apple Silicon).
#   2. Генерим background image со стрелкой «перетащи в Applications».
#   3. R/W DMG → монтируем → копируем app + симлинк + .background.
#   4. AppleScript: расставляем иконки, прячем toolbar/sidebar, ставим фон.
#   5. Размонтируем, конвертируем в сжатый R/O DMG.
#   6. Custom Finder-иконка на самом DMG-файле.
#
# Запуск из корня репо:
#   ./scripts/package.sh
#
# Результат: ~/Downloads/Glagol.dmg
#
# Без подписи Apple — получатель должен сделать Right-click → Open при
# первом запуске (Gatekeeper). Для полноценного distribution нужен
# Developer ID + notarization.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="/tmp/glagol-release"
APP="$DERIVED/Build/Products/Release/glagol.app"
DMG_FINAL="$HOME/Downloads/Glagol.dmg"
DMG_RW="/tmp/Glagol-rw.dmg"
STAGING="/tmp/glagol-dmg-stage"
MOUNT_POINT="/Volumes/Glagol"
ICON_PNG="$REPO_ROOT/glagol/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
BG_PNG="/tmp/glagol-bg.png"

# Размер окна DMG. Должен совпадать с размером background-картинки
# (см. generate_dmg_background.swift).
WINDOW_W=600
WINDOW_H=400

echo "▸ Clean Release build (arm64)…"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "$REPO_ROOT/glagol.xcodeproj" \
  -scheme glagol \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  clean build > /tmp/glagol-release.log 2>&1

if [ ! -d "$APP" ]; then
  echo "✗ Build не создал .app — см. /tmp/glagol-release.log"
  exit 1
fi

echo "▸ Background image…"
swift "$REPO_ROOT/scripts/generate_dmg_background.swift" "$BG_PNG"

echo "▸ Staging-папка…"
rm -rf "$STAGING" "$DMG_RW" "$DMG_FINAL"
mkdir "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
cp "$BG_PNG" "$STAGING/.background/background.png"

# Размер RW-DMG: суммарный размер staging + 20МБ запас.
STAGE_SIZE_MB=$(du -sm "$STAGING" | cut -f1)
RW_SIZE_MB=$((STAGE_SIZE_MB + 20))

echo "▸ Создаём R/W DMG (~${RW_SIZE_MB} МБ)…"
# Размонтируем предыдущие маунты Glagol если остались висеть от прошлых сборок
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
hdiutil create \
  -volname "Glagol" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDRW \
  -size "${RW_SIZE_MB}m" \
  "$DMG_RW" > /dev/null

echo "▸ Монтируем и применяем layout…"
hdiutil attach "$DMG_RW" -nobrowse -noautoopen > /dev/null
# Финдеру нужна пауза чтобы заметить новый том
sleep 2

# AppleScript: задаёт окну Finder'а нужный размер, выключает sidebar/toolbar,
# ставит фон, расставляет иконки. Координаты в Finder'е — от верхнего-левого
# угла окна. Те же 150/450 что в background-картинке, y=220 это центр
# иконки (соответствует y=180 от низа в AppKit-генерации фона).
osascript - <<APPLESCRIPT
tell application "Finder"
    tell disk "Glagol"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set bounds of container window to {200, 100, ${WINDOW_W} + 200, ${WINDOW_H} + 100}

        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"

        set position of item "glagol.app" of container window to {150, 220}
        set position of item "Applications" of container window to {450, 220}

        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Финдер должен записать .DS_Store перед размонтированием
sync
sleep 2

echo "▸ Размонтируем…"
hdiutil detach "$MOUNT_POINT" -quiet || hdiutil detach "$MOUNT_POINT" -force

echo "▸ Конвертируем в сжатый R/O DMG…"
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" > /dev/null
rm "$DMG_RW"
rm -rf "$STAGING"

echo "▸ Custom иконка на DMG-файле…"
swift "$REPO_ROOT/scripts/set_dmg_icon.swift" "$ICON_PNG" "$DMG_FINAL"

# Финдер кеширует иконки — рестарт чтобы новая сразу была видна
killall Finder 2>/dev/null || true

echo ""
echo "✓ Готово: $DMG_FINAL ($(du -h "$DMG_FINAL" | cut -f1))"
