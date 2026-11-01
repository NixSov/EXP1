#!/bin/sh
# Сборка модпака «Приключения» в dist/Adventure.mcaddon
set -e
cd "$(dirname "$0")/.."
python3 tools/adv_generate.py
mkdir -p dist
rm -f dist/Adventure.mcaddon
zip -qr dist/Adventure.mcaddon AdventureBP AdventureRP -x '*.DS_Store'
echo "Готово: dist/Adventure.mcaddon"
