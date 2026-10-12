#!/bin/bash
# Упаковка «Ромашки» в DMG для передачи коллегам.
# Внутри: приложение, ярлык «Applications», инструкция по установке, иконка тома.
set -euo pipefail
cd "$(dirname "$0")/.."                       # корень проекта

VERSION="1.0"
APP="app/build/Romashka.app"
DIST="dist"
VOLNAME="Ромашка $VERSION"
NAME="Romashka-$VERSION-universal.dmg"
STAGE="$DIST/stage"
RW="$DIST/rw.dmg"
MNT="$DIST/mnt"

[ -d "$APP" ] || { echo "нет $APP — сначала соберите: app/build.sh"; exit 1; }
command -v hdiutil >/dev/null || { echo "нет hdiutil"; exit 1; }

rm -rf "$DIST"
mkdir -p "$STAGE" "$MNT"

echo "== складываю содержимое"
ditto "$APP" "$STAGE/Romashka.app"            # ditto сохраняет подпись и атрибуты
ln -s /Applications "$STAGE/Applications"
cp tools/dmg-readme.txt "$STAGE/Как установить.txt"
cp app/Resources/Romashka.icns "$STAGE/.VolumeIcon.icns"

# права приводим к читаемым для всех: иначе у коллеги с другим uid
# инструкция и содержимое бандла окажутся недоступны (600 при чужом владельце)
chmod -R a+rX "$STAGE"
chmod 644 "$STAGE/Как установить.txt" "$STAGE/.VolumeIcon.icns"

echo "== образ для записи"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW -quiet "$RW"

echo "== иконка тома"
hdiutil attach "$RW" -nobrowse -quiet -mountpoint "$MNT"
if SetFile -a C "$MNT" 2>/dev/null; then echo "   поставлена"; else echo "   не удалось (не критично)"; fi
sync
hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet

echo "== сжатие"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DIST/$NAME" -quiet
rm -rf "$RW" "$STAGE" "$MNT"

echo "== проверка образа"
hdiutil verify "$DIST/$NAME" | tail -1
shasum -a 256 "$DIST/$NAME" > "$DIST/$NAME.sha256"
cat "$DIST/$NAME.sha256"
printf '\nготово: %s (%s)\n' "$DIST/$NAME" "$(du -h "$DIST/$NAME" | cut -f1)"
