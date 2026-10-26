#!/usr/bin/env python3
"""Генерирует иконки приложения из assets/icon/icon.jpg (нужен Pillow)."""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android/app/src/main/res"
SRC = Image.open(ROOT / "assets/icon/icon.jpg").convert("RGB")

# Цвет подложки адаптивной иконки — тёмный край карты.
BACKGROUND = "#3A3326"
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def resized(size: int) -> Image.Image:
    return SRC.resize((size, size), Image.LANCZOS)


for name, scale in DENSITIES.items():
    folder = RES / f"mipmap-{name}"
    folder.mkdir(parents=True, exist_ok=True)
    # Обычная иконка (Android 7 и старше): картинка целиком.
    resized(round(48 * scale)).save(folder / "ic_launcher.png", optimize=True)
    # Передний слой адаптивной иконки: холст 108dp, картинка 70dp по центру,
    # чтобы маска лаунчера (видимая зона ~72dp) не обрезала шестиугольники.
    canvas = round(108 * scale)
    inner = round(70 * scale)
    fg = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    offset = (canvas - inner) // 2
    fg.paste(resized(inner), (offset, offset))
    fg.save(folder / "ic_launcher_foreground.png", optimize=True)

anydpi = RES / "mipmap-anydpi-v26"
anydpi.mkdir(exist_ok=True)
(anydpi / "ic_launcher.xml").write_text(
    """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
""",
    encoding="utf-8",
)
(RES / "values/ic_launcher_background.xml").write_text(
    f"""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{BACKGROUND}</color>
</resources>
""",
    encoding="utf-8",
)

# Иконка для Windows-версии.
SRC.save(
    ROOT / "windows/runner/resources/app_icon.ico",
    sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
)
print("Иконки обновлены")
