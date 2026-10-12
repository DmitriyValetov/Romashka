#!/bin/bash
# Готовит демонстрационное дерево и снимает на нём скриншоты и макет ромашки.
# Нужно, чтобы в публичный репозиторий не попадали настоящие каталоги пользователя:
# все снимки для README делаются на синтетическом дереве с нейтральными именами.
#
# usage: tools/make_demo_assets.sh <каталог-вывода>
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/publish}"
BIN="app/build/Romashka.app/Contents/MacOS/Romashka"
PY="${PYTHON:-python3}"
DEMO="/tmp/romashka-demo/Демо"          # путь в кадре не должен выдавать домашний каталог

[ -x "$BIN" ] || { echo "нет сборки: сначала app/build.sh"; exit 1; }
command -v clang++ >/dev/null || { echo "нужен clang++ (Command Line Tools: xcode-select --install)"; exit 1; }
$PY -c 'import PIL' 2>/dev/null || { echo "для макета нужен Pillow: pip3 install pillow (или PYTHON=/путь/к/python3)"; exit 1; }
if [ ! -x bench/fastscan ]; then            # в репозитории его нет — это артефакт сборки
  echo "== собираю bench/fastscan"
  clang++ -O2 -std=c++17 -o bench/fastscan bench/fastscan.cpp
fi
mkdir -p "$OUT/screenshots" "$OUT/mockup"
rm -f "$OUT/screenshots"/*.png                      # не тащим снимки прошлых прогонов

rm -rf /tmp/romashka-demo
echo "== дерево в $DEMO"
mk() { mkdir -p "$1"; }
blob() {  # blob <файл> <МБ>
  mkdir -p "$(dirname "$1")"
  dd if=/dev/zero of="$1" bs=1m count="$2" 2>/dev/null
}
sprinkle() {  # sprinkle <каталог> <сколько файлов> <КБ каждый>
  mkdir -p "$1"
  for i in $(seq 1 "$2"); do
    dd if=/dev/zero of="$1/файл_$(printf '%03d' "$i").dat" bs=1k count="$3" 2>/dev/null
  done
}

# Проекты: один тяжёлый образ и много мелочи
blob "$DEMO/Проекты/Веб-сервис/образ_виртуальной_машины.img" 380
sprinkle "$DEMO/Проекты/Веб-сервис/исходники" 120 40
sprinkle "$DEMO/Проекты/Веб-сервис/логи" 60 24
sprinkle "$DEMO/Проекты/Мобильное приложение/сборки" 40 48
sprinkle "$DEMO/Проекты/Мобильное приложение/ресурсы" 80 16
sprinkle "$DEMO/Проекты/Аналитика/выгрузки" 30 40

# Кэши: пакеты и модели
sprinkle "$DEMO/Кэши/Пакеты/архивы" 90 36
sprinkle "$DEMO/Кэши/Пакеты/индексы" 50 12
blob "$DEMO/Кэши/Модели/модель_распознавания.onnx" 200
sprinkle "$DEMO/Кэши/Модели/токенизаторы" 20 8

# Медиа
blob "$DEMO/Медиа/Видео/запись_экрана.mov" 220
sprinkle "$DEMO/Медиа/Фото/снимки" 70 22

# Резервные копии
blob "$DEMO/Резервные копии/архив_2026-10.zip" 180
sprinkle "$DEMO/Резервные копии/старое" 25 20

echo "== снимки интерфейса"
"$BIN" --render "$OUT/screenshots/overview.png" --live 60 --path "$DEMO" >/dev/null 2>&1
"$BIN" --render "$OUT/screenshots/media.png" --live 60 --path "$DEMO/Медиа" >/dev/null 2>&1
"$BIN" --render "$OUT/screenshots/large-files.png" --files --live 60 --path "$DEMO" >/dev/null 2>&1

echo "== макет ромашки (двухпанельный)"
JSON="$(mktemp -d)/demo.json"
"$BIN" --selftest "$DEMO" --jobs 4 >/dev/null 2>&1 || true
./bench/fastscan -j 4 -m 1 --json "$JSON" "$DEMO" >/dev/null 2>&1
cp "$JSON" "$OUT/mockup/demo.json"
"${PYTHON:-python3}" mockup/render.py "$OUT/mockup/demo.json" "$OUT/mockup/romashka_mockup.png"

du -sh "$DEMO" | sed 's/^/   дерево: /'
ls -1 "$OUT/screenshots" | sed 's/^/   /'
rm -rf "$(dirname "$DEMO")"
echo "== готово"
