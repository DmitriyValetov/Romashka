#!/bin/bash
# Сборка «Ромашки» без Xcode: clang++ для движка, swiftc для интерфейса,
# .app собирается вручную, подписывается ад-хок. Бинарник — универсальный
# (arm64 + x86_64), чтобы приложение запускалось и на Intel-маках.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build"
APP="$OUT/Romashka.app"
BIN="$APP/Contents/MacOS/Romashka"
ARCHS="arm64 x86_64"
TARGET_MIN="macos14.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT"

echo "== иконка"
if [ ! -f Resources/Romashka.icns ]; then
  python3 ../tools/make_icon.py Resources/Romashka.icns
fi

SLICES=()
for A in $ARCHS; do
  echo "== движок ($A)"
  clang++ -O2 -std=c++17 -Wall -target "$A-apple-$TARGET_MIN" \
    -c Engine/rk_engine.cpp -o "$OUT/rk_engine-$A.o"
  echo "== интерфейс ($A)"
  swiftc -O -parse-as-library \
    -target "$A-apple-$TARGET_MIN" \
    -import-objc-header Engine/rk_engine.h \
    -o "$OUT/Romashka-$A" \
    Sources/Core.swift Sources/Sunburst.swift Sources/AppState.swift Sources/Views.swift Sources/main.swift \
    "$OUT/rk_engine-$A.o" -lc++
  SLICES+=("$OUT/Romashka-$A")
done

echo "== склейка архитектур"
lipo -create -output "$BIN" "${SLICES[@]}"
lipo -info "$BIN"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Romashka.icns "$APP/Contents/Resources/Romashka.icns"

echo "== подпись"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
codesign -dv "$APP" 2>&1 | sed -n '1,3p'

echo "== готово: $APP"
printf '   бинарник: %s байт\n' "$(stat -f '%z' "$BIN")"
