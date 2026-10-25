#!/bin/sh
# Сборка: генерация ресурсов и упаковка в dist/Awakening.mcaddon
set -e
cd "$(dirname "$0")/.."
python3 tools/generate.py
mkdir -p dist
rm -f dist/Awakening.mcaddon
zip -qr dist/Awakening.mcaddon AwakeningBP AwakeningRP -x '*.DS_Store'
echo "Готово: dist/Awakening.mcaddon"
