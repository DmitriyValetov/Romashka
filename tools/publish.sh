#!/bin/bash
# Публикация проекта на GitHub.
#
# Собирает чистый репозиторий в build/repo: исходники, документация и снимки —
# но снимки только демонстрационные (tools/make_demo_assets.sh делает их на синтетическом
# дереве в /tmp), чтобы настоящие каталоги пользователя не уходили в публичный репозиторий.
# Затем коммит и (с --push) отправка в origin/main.
#
# usage: tools/publish.sh [--push]
#        PYTHON=/путь/к/python3 tools/publish.sh        (нужен Pillow для макета)
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE="${REMOTE:-https://github.com/DmitriyValetov/Romashka.git}"
REPO="build/repo"
AUTHOR_NAME="${AUTHOR_NAME:-Dmitriy Valetov}"
AUTHOR_MAIL="${AUTHOR_MAIL:-27976850+DmitriyValetov@users.noreply.github.com}"
PY="${PYTHON:-python3}"
PUSH="${1:-}"
RELEASE_TAG="${RELEASE_TAG:-v1.0}"

[ -x app/build/Romashka.app/Contents/MacOS/Romashka ] || { echo "сначала соберите приложение: app/build.sh"; exit 1; }
$PY -c 'import PIL' 2>/dev/null || { echo "нужен Pillow: PYTHON=/путь/к/python3 с Pillow $0"; exit 1; }

echo "== демонстрационные материалы (настоящие каталоги в репозиторий не идут)"
PYTHON="$PY" tools/make_demo_assets.sh build/publish >/dev/null

echo "== клон с историей"
if [ -d "$REPO/.git" ]; then
  git -C "$REPO" fetch origin --quiet
  git -C "$REPO" reset --hard origin/main --quiet
else
  mkdir -p build
  git clone --quiet "$REMOTE" "$REPO"
fi
git -C "$REPO" config user.name "$AUTHOR_NAME"
git -C "$REPO" config user.email "$AUTHOR_MAIL"

echo "== раскладываю файлы"
rm -rf "$REPO/app" "$REPO/bench" "$REPO/docs" "$REPO/mockup" "$REPO/screenshots" "$REPO/tools"
mkdir -p "$REPO"/{app,bench,docs,mockup,screenshots,tools}
cp -R app/Sources app/Engine app/Resources "$REPO/app/"
cp app/build.sh app/Info.plist "$REPO/app/"
mkdir -p "$REPO/bench/app_feasibility"
cp bench/fastscan.cpp bench/probe.cpp "$REPO/bench/"
cp bench/app_feasibility/App.swift "$REPO/bench/app_feasibility/"
cp docs/design.md docs/app.md "$REPO/docs/"
cp mockup/render.py "$REPO/mockup/"
cp build/publish/mockup/romashka_mockup.png "$REPO/mockup/"
cp build/publish/mockup/demo.json "$REPO/mockup/demo-tree.json"
cp build/publish/screenshots/*.png "$REPO/screenshots/"
cp tools/make_icon.py tools/make_dmg.sh tools/make_demo_assets.sh tools/publish.sh tools/dmg-readme.txt "$REPO/tools/"
cp tools/repo-readme.md "$REPO/README.md"

cat > "$REPO/.gitignore" <<'EOF'
# сборка и артефакты
build/
dist/
*.o
bench/fastscan
bench/probe

# системный мусор
.DS_Store

# данные сканирования: содержат реальные пути того, кто запускал
mockup/home.json
mockup/*.json
!mockup/demo-tree.json
reports/
EOF

echo "== чищу личные упоминания в текстовых файлах"
find "$REPO" -type f \( -name '*.md' -o -name '*.swift' -o -name '*.cpp' -o -name '*.h' \
  -o -name '*.sh' -o -name '*.py' -o -name '*.plist' -o -name '*.txt' \) -print0 |
  xargs -0 sed -i '' \
    -e 's|~|~|g' \
    -e 's|~/Romashka|~/Romashka|g' \
    -e 's|~/рабочий_проект|~/рабочий_проект|g' \
    -e 's|dkvaletov@sberdevices\.ru|почта-скрыта|g' \
    -e 's|Макет построен \*\*на настоящих данных\*\* этого диска (`mockup/home.json`, снят прототипом|Макет построен на демонстрационном дереве (`mockup/demo-tree.json`, снимок делает `tools/make_demo_assets.sh`); замеры ниже — на реальном диске (снят прототипом|' \
    -e 's|воспроизводится через `--selftest`|воспроизводится через `--selftest`|g' \
    -e 's|построен на демонстрационном дереве|построен на демонстрационном дереве|' \
    -e 's|движка): слева — корень обхода, справа — тот же вид после клика в самый тяжёлый сегмент.|движка): слева — корень обхода, справа — тот же вид после клика в самый тяжёлый сегмент.|' \
    -e 's|\*\*настоящих данных\*\* этого диска|демонстрационного дерева|g'

echo "== проверка: личные упоминания"
if grep -rIl -E 'dkvaletov|prod_eda|mlspace|MolmoWeb|sberdevices' "$REPO" --exclude-dir=.git 2>/dev/null | grep -v 'publish.sh'; then
  echo "   ^^ найдено, разберитесь перед отправкой"; exit 1
else
  echo "   чисто"
fi

echo "== git"
git -C "$REPO" add -A
git -C "$REPO" -c core.quotepath=false status --short | head -40
echo "   файлов: $(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')"

if [ "$PUSH" = "--push" ]; then
  MESSAGE="Ромашка: приложение для поиска тяжёлых папок на macOS

Sunburst по каталогам с иерархическим провалом: угол — доля размера, кольцо — уровень
вложенности, клик — провал внутрь. Ничего не удаляет: удаление пользователь делает в Finder.

• движок на C++ (getattrlistbulk + пул потоков, C-API для Swift) — 3.7 млн объектов / 756 ГБ за 19.7 с
• интерфейс на SwiftUI: ромашка на Canvas, живой обход, списки каталогов и крупных файлов
• сборка без Xcode (CommandLineTools), универсальный бинарник arm64 + x86_64, упаковка в DMG
• проверки: инвариант дерева size == own + Σ(детей), сверка с du ≤ 0.03 %, режимы --selftest/--render/--live"

  # история должна читаться: «Initial commit» + один коммит содержимого.
  # Каждая публикация не плодит коммиты с одинаковым сообщением, а перезаписывает свой.
  FORCE=""
  if git -C "$REPO" log -1 --format=%s | grep -q '^Ромашка: приложение'; then
    git -C "$REPO" commit --quiet --amend -m "$MESSAGE"
    FORCE="--force-with-lease"
  else
    git -C "$REPO" commit --quiet -m "$MESSAGE"
  fi
  git -C "$REPO" push $FORCE origin main

  # тег релиза держим на опубликованном коммите, иначе ссылка «v1.0» покажет устаревшее дерево
  if git -C "$REPO" rev-parse --verify --quiet "$RELEASE_TAG" >/dev/null; then
    git -C "$REPO" tag -f "$RELEASE_TAG" >/dev/null
    git -C "$REPO" push --force origin "$RELEASE_TAG" | tail -1
  fi
  echo "== отправлено: $REMOTE"
else
  echo "== готово (без отправки). Отправить: tools/publish.sh --push"
fi
