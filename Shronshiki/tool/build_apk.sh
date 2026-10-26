#!/usr/bin/env bash
# Сборка APK для установки напрямую на телефон.
# Если есть config/app_config.json — ключи Supabase/TURN встраиваются в APK,
# иначе приложение попросит ввести их при первом запуске.
set -euo pipefail
cd "$(dirname "$0")/.."

# Отдельные APK под архитектуры: так файл в ~3 раза меньше универсального.
args=(build apk --release --split-per-abi --target-platform android-arm,android-arm64)
if [[ -f config/app_config.json ]]; then
  args+=(--dart-define-from-file=config/app_config.json)
  echo "Используются настройки из config/app_config.json"
else
  echo "config/app_config.json не найден — APK будет без встроенных ключей"
fi

flutter "${args[@]}"
mkdir -p dist
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk dist/Shronshiki.apk
cp build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk dist/Shronshiki-armv7.apk
echo "Готово: $(pwd)/dist/Shronshiki.apk (почти все телефоны)"
echo "        $(pwd)/dist/Shronshiki-armv7.apk (старые 32-битные телефоны)"
