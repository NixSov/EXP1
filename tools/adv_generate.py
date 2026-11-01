#!/usr/bin/env python3
"""Генератор ресурсов модпака «Приключения» (AdventureBP / AdventureRP).

Создаёт:
  - иконки предметов и кнопок меню;
  - лист символов карты font/glyph_E3.png (клетки местности и метки);
  - JSON предметов и рецептов;
  - переводы;
  - AdventureBP/scripts/glyphs.js — таблица символов для скриптов.
"""
import json
import os
import random

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BP = os.path.join(ROOT, "AdventureBP")
RP = os.path.join(ROOT, "AdventureRP")
ITEM_TEX = os.path.join(RP, "textures", "items", "adv")
UI_TEX = os.path.join(RP, "textures", "ui", "adv")

GLYPH_PAGE = 0xE3

# Категории местности: (ключ, название, основной цвет)
TERRAIN = [
    ("unknown", "не загружено", (18, 18, 22)),
    ("water", "вода", (52, 96, 214)),
    ("lava", "лава", (230, 96, 20)),
    ("grass", "трава", (96, 160, 58)),
    ("foliage", "листва", (44, 112, 36)),
    ("sand", "песок", (222, 206, 146)),
    ("snow", "снег и лёд", (236, 244, 252)),
    ("stone", "камень", (128, 128, 128)),
    ("dirt", "земля", (134, 96, 62)),
    ("wood", "дерево", (164, 128, 78)),
    ("nether", "незер", (128, 38, 38)),
    ("end", "энд", (220, 222, 160)),
    ("dark", "обсидиан", (40, 30, 56)),
    ("clay", "терракота", (176, 98, 60)),
    ("cave", "пустота пещеры", (70, 70, 76)),
]
SHADES = (0.68, 1.0, 1.28)  # ниже игрока, на уровне, выше

MARKERS = ["self_n", "self_ne", "self_e", "self_se", "self_s", "self_sw", "self_w", "self_nw",
           "player", "hostile", "passive", "waypoint", "death", "dungeon"]
MARKER_BASE = 0x40

GRAPPLE_TIERS = [
    # (уровень, дальность, скорость подтягивания блоков/тик, скорость полёта крюка, материал улучшения)
    (1, 20, 0.9, 3.0, None),
    (2, 30, 1.15, 4.0, ("minecraft:iron_ingot", 3)),
    (3, 40, 1.4, 5.0, ("minecraft:gold_ingot", 3)),
    (4, 52, 1.7, 6.5, ("minecraft:diamond", 2)),
    (5, 64, 2.0, 8.0, ("minecraft:netherite_ingot", 1)),
]
TIER_COLORS = [(150, 150, 150), (220, 220, 225), (250, 205, 60), (90, 230, 220), (90, 70, 90)]


def shade(c, k):
    return tuple(max(0, min(255, int(v * k))) for v in c)


def outline(img, color):
    px = img.load()
    out = img.copy()
    opx = out.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            if px[x, y][3]:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3]:
                    opx[x, y] = color + (255,)
                    break
    return out


# ---------------------------------------------------------------- символы карты

def terrain_cell(color, rnd):
    cell = Image.new("RGBA", (16, 16))
    p = cell.load()
    for y in range(16):
        for x in range(16):
            k = 1 + (rnd.random() - 0.5) * 0.12
            p[x, y] = shade(color, k) + (255,)
    return cell


def marker_cell(kind):
    cell = Image.new("RGBA", (16, 16), (30, 30, 34, 255))
    d = ImageDraw.Draw(cell)
    if kind.startswith("self_"):
        dirs = {"n": 0, "ne": 45, "e": 90, "se": 135, "s": 180, "sw": 225, "w": 270, "nw": 315}
        a = dirs[kind[5:]]
        import math
        r = math.radians(a)

        def rot(x, y):
            return (8 + x * math.cos(r) - y * math.sin(r), 8 + x * math.sin(r) + y * math.cos(r))

        pts = [rot(0, -7), rot(5.5, 6), rot(0, 3), rot(-5.5, 6)]
        d.polygon(pts, fill=(255, 255, 255, 255), outline=(220, 30, 30, 255))
    elif kind == "player":
        d.ellipse((3, 3, 12, 12), fill=(70, 160, 255, 255), outline=(255, 255, 255, 255))
    elif kind == "hostile":
        d.ellipse((4, 4, 11, 11), fill=(230, 40, 40, 255))
    elif kind == "passive":
        d.ellipse((4, 4, 11, 11), fill=(250, 240, 240, 255))
    elif kind == "waypoint":
        d.line((5, 2, 5, 14), fill=(240, 240, 240, 255), width=2)
        d.polygon([(6, 2), (13, 5), (6, 8)], fill=(255, 210, 40, 255))
    elif kind == "death":
        d.ellipse((3, 2, 12, 11), fill=(235, 235, 235, 255))
        d.rectangle((5, 10, 10, 13), fill=(235, 235, 235, 255))
        d.rectangle((5, 5, 6, 7), fill=(20, 20, 20, 255))
        d.rectangle((9, 5, 10, 7), fill=(20, 20, 20, 255))
    elif kind == "dungeon":
        d.rectangle((3, 5, 12, 13), fill=(120, 110, 100, 255))
        d.rectangle((6, 8, 9, 13), fill=(20, 15, 10, 255))
        for x in (3, 6, 9, 12):
            d.rectangle((x, 3, x, 4), fill=(120, 110, 100, 255))
    return cell


def make_glyphs():
    sheet = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    rnd = random.Random(7)
    js_terrain = {}
    for ci, (key, _, color) in enumerate(TERRAIN):
        codes = []
        for si, k in enumerate(SHADES):
            idx = ci * 3 + si
            sheet.paste(terrain_cell(shade(color, k), rnd), ((idx % 16) * 16, (idx // 16) * 16))
            codes.append(chr((GLYPH_PAGE << 8) | idx))
        js_terrain[key] = codes
    js_markers = {}
    for mi, kind in enumerate(MARKERS):
        idx = MARKER_BASE + mi
        sheet.paste(marker_cell(kind), ((idx % 16) * 16, (idx // 16) * 16))
        js_markers[kind] = chr((GLYPH_PAGE << 8) | idx)
    font = os.path.join(RP, "font")
    os.makedirs(font, exist_ok=True)
    sheet.save(os.path.join(font, f"glyph_{GLYPH_PAGE:02X}.png"))
    return js_terrain, js_markers


# ---------------------------------------------------------------- иконки

def icon_navigator():
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((1, 2, 14, 13), fill=(226, 210, 160, 255))
    d.rectangle((2, 3, 13, 12), fill=(110, 170, 80, 255))
    d.rectangle((2, 8, 7, 12), fill=(70, 110, 220, 255))
    d.rectangle((9, 3, 13, 6), fill=(130, 130, 130, 255))
    d.polygon([(8, 4), (11, 10), (8, 9), (5, 10)], fill=(255, 255, 255, 255), outline=(200, 30, 30, 255))
    return outline(img, (60, 45, 30))


def icon_grapple(tier):
    tip = TIER_COLORS[tier - 1]
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # рукоять
    d.line((2, 13, 7, 8), fill=(120, 80, 40, 255), width=2)
    # верёвка
    for i, (x, y) in enumerate(((1, 10), (2, 8), (1, 6), (2, 4), (3, 2))):
        img.putpixel((x, y), (230, 220, 200, 255))
    # крюк
    d.line((7, 8, 11, 4), fill=tip + (255,), width=2)
    d.line((11, 4, 14, 3), fill=tip + (255,), width=1)
    d.line((11, 4, 12, 1), fill=tip + (255,), width=1)
    d.line((11, 4, 14, 6), fill=tip + (255,), width=1)
    img.putpixel((14, 2), shade(tip, 1.25) + (255,))
    img.putpixel((12, 0), shade(tip, 1.25) + (255,))
    img.putpixel((15, 6), shade(tip, 1.25) + (255,))
    img = outline(img, (35, 30, 30))
    # римская цифра уровня точками
    for i in range(tier):
        img.putpixel((9 + i, 14), (255, 255, 255, 255))
    return img


def icon_backpack():
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((3, 3, 12, 14), radius=3, fill=(150, 92, 48, 255))
    d.rectangle((3, 3, 12, 7), fill=(120, 70, 36, 255))
    d.rectangle((5, 9, 10, 13), fill=(176, 112, 62, 255))
    d.rectangle((7, 6, 8, 8), fill=(230, 200, 80, 255))
    d.arc((5, 0, 10, 6), 180, 360, fill=(90, 55, 30, 255), width=1)
    return outline(img, (50, 30, 15))


def ui_icon(kind):
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    white = (245, 245, 245, 255)
    if kind in ("zoom_in", "zoom_out"):
        d.ellipse((1, 1, 10, 10), outline=white, width=2)
        d.line((9, 9, 14, 14), fill=white, width=3)
        d.line((3, 5, 8, 5), fill=white, width=1)
        d.line((3, 6, 8, 6), fill=white, width=1)
        if kind == "zoom_in":
            d.line((5, 3, 5, 8), fill=white, width=1)
            d.line((6, 3, 6, 8), fill=white, width=1)
    elif kind == "add_wp":
        img.paste(marker_cell("waypoint").crop((0, 0, 16, 16)), (0, 0))
        img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.line((4, 1, 4, 15), fill=white, width=2)
        d.polygon([(5, 1), (14, 4), (5, 8)], fill=(255, 210, 40, 255))
        d.line((10, 11, 15, 11), fill=(90, 230, 90, 255), width=2)
        d.line((12, 9, 12, 14), fill=(90, 230, 90, 255), width=2)
    elif kind == "list":
        for y in (3, 7, 11):
            d.rectangle((1, y, 3, y + 2), fill=(255, 210, 40, 255))
            d.rectangle((5, y, 14, y + 1), fill=white)
    elif kind == "settings":
        d.ellipse((2, 2, 13, 13), outline=white, width=3)
        for x, y in ((7, 0), (7, 13), (0, 7), (13, 7)):
            d.rectangle((x, y, x + 1, y + 2 if y != 7 else y + 1), fill=white)
        d.ellipse((6, 6, 9, 9), fill=white)
    elif kind in ("waypoint", "death", "dungeon"):
        img = marker_cell(kind)
    elif kind == "teleport":
        d.ellipse((2, 2, 13, 13), outline=(200, 90, 255, 255), width=2)
        d.ellipse((5, 5, 10, 10), fill=(230, 160, 255, 255))
    elif kind == "rename":
        d.line((3, 12, 12, 3), fill=(255, 210, 40, 255), width=3)
        d.polygon([(2, 14), (2, 11), (5, 14)], fill=white)
    elif kind == "delete":
        d.line((3, 3, 12, 12), fill=(240, 60, 60, 255), width=3)
        d.line((12, 3, 3, 12), fill=(240, 60, 60, 255), width=3)
    elif kind == "back":
        d.polygon([(2, 8), (8, 2), (8, 5), (14, 5), (14, 11), (8, 11), (8, 14)], fill=white)
    return img.resize((32, 32), Image.NEAREST)


# ---------------------------------------------------------------- окно карты (JSON UI)

# Цвета как у ванильной карты Minecraft
MAP_COLORS = {
    "unknown": (214, 190, 150),
    "water": (64, 64, 255),
    "lava": (255, 96, 0),
    "grass": (127, 178, 56),
    "foliage": (0, 124, 0),
    "sand": (247, 233, 163),
    "snow": (255, 255, 255),
    "stone": (112, 112, 112),
    "dirt": (151, 109, 77),
    "wood": (143, 119, 72),
    "nether": (112, 2, 0),
    "end": (229, 229, 153),
    "dark": (25, 25, 25),
    "clay": (160, 77, 78),
    "cave": (82, 82, 88),
}
MAP_SHADES = (180 / 255, 220 / 255, 1.0)


def map_tile(cat, shade_idx, rnd):
    base = shade(MAP_COLORS[cat], MAP_SHADES[shade_idx])
    t = Image.new("RGBA", (8, 8))
    p = t.load()
    for y in range(8):
        for x in range(8):
            k = 1.0
            if cat in ("grass", "foliage", "sand", "dirt", "stone", "snow", "unknown"):
                k = 1 + (rnd.random() - 0.5) * 0.1
            if cat == "foliage" and rnd.random() < 0.18:
                k = 0.78
            if cat == "grass" and rnd.random() < 0.08:
                k = 0.86
            if cat == "water" and (x + y * 3) % 7 == 0:
                k = 1.12
            if cat == "lava" and rnd.random() < 0.2:
                k = 1.15
            p[x, y] = shade(base, k) + (255,)
    return t.resize((16, 16), Image.NEAREST)


def map_marker(kind):
    cell = marker_cell(kind).copy()
    # фон метки прозрачный — сквозь него виден пергамент рамки
    px = cell.load()
    for y in range(16):
        for x in range(16):
            if px[x, y][:3] == (30, 30, 34):
                px[x, y] = (0, 0, 0, 0)
    return cell


def make_map_ui():
    d = os.path.join(UI_TEX, "map")
    os.makedirs(d, exist_ok=True)
    rnd = random.Random(11)
    for cat in MAP_COLORS:
        for si in range(3):
            map_tile(cat, si, rnd).save(os.path.join(d, f"{cat}_{si}.png"))
    for kind in MARKERS:
        map_marker(kind).save(os.path.join(d, f"m_{kind}.png"))

    # рамка-пергамент как у ванильной карты (9-slice)
    fr = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    fp = fr.load()
    r2 = random.Random(3)
    for y in range(32):
        for x in range(32):
            edge = min(x, y, 31 - x, 31 - y)
            if edge <= 1:
                c = (110, 84, 50) if r2.random() < 0.7 else (30, 22, 14)
            elif edge <= 5:
                c = (199, 172, 128) if r2.random() < 0.8 else (170, 140, 98)
            else:
                c = (214, 190, 150)
            fp[x, y] = c + (255,)
    fr.save(os.path.join(UI_TEX, "map_frame.png"))
    write_json(os.path.join(UI_TEX, "map_frame.json"), {"nineslice_size": 6, "base_size": [32, 32]})

    # тёмный фон окна (9-slice)
    bg = Image.new("RGBA", (16, 16), (40, 42, 50, 245))
    bd = ImageDraw.Draw(bg)
    bd.rectangle((0, 0, 15, 15), outline=(12, 12, 16, 255))
    bd.rectangle((1, 1, 14, 14), outline=(88, 90, 104, 255))
    bg.save(os.path.join(UI_TEX, "panel_bg.png"))
    write_json(os.path.join(UI_TEX, "panel_bg.json"), {"nineslice_size": 3, "base_size": [16, 16]})

    # кнопки действий (9-slice) и крестик закрытия
    for name, fill, top in (("btn", (70, 74, 88), (104, 108, 126)),
                            ("btn_hover", (52, 120, 60), (90, 170, 96)),
                            ("btn_pressed", (34, 84, 40), (52, 110, 58))):
        b = Image.new("RGBA", (16, 16), fill + (255,))
        bdr = ImageDraw.Draw(b)
        bdr.rectangle((0, 0, 15, 15), outline=(10, 10, 14, 255))
        bdr.line((1, 1, 14, 1), fill=top + (255,))
        bdr.line((1, 14, 14, 14), fill=shade(fill, 0.6) + (255,))
        b.save(os.path.join(UI_TEX, name + ".png"))
        write_json(os.path.join(UI_TEX, name + ".json"), {"nineslice_size": 3, "base_size": [16, 16]})
    for name, col in (("close", (220, 220, 220)), ("close_hover", (255, 90, 90))):
        c = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
        cd = ImageDraw.Draw(c)
        cd.line((3, 3, 12, 12), fill=col + (255,), width=2)
        cd.line((12, 3, 3, 12), fill=col + (255,), width=2)
        c.save(os.path.join(UI_TEX, name + ".png"))


# ---------------------------------------------------------------- JSON

def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


def item_json(identifier, icon, category="equipment", extra=None):
    comps = {
        "minecraft:icon": {"textures": {"default": icon}},
        "minecraft:max_stack_size": 1,
    }
    if extra:
        comps.update(extra)
    return {
        "format_version": "1.21.40",
        "minecraft:item": {
            "description": {"identifier": identifier, "menu_category": {"category": category}},
            "components": comps,
        },
    }


def shapeless(ident, ingredients, result):
    return {
        "format_version": "1.20.10",
        "minecraft:recipe_shapeless": {
            "description": {"identifier": ident},
            "tags": ["crafting_table"],
            "ingredients": ingredients,
            "result": {"item": result},
        },
    }


def main():
    for d in (ITEM_TEX, UI_TEX):
        os.makedirs(d, exist_ok=True)
    items_dir = os.path.join(BP, "items")
    rec_dir = os.path.join(BP, "recipes")
    for d in (items_dir, rec_dir):
        os.makedirs(d, exist_ok=True)
        for f in os.listdir(d):
            os.remove(os.path.join(d, f))

    textures = {}
    lang = [
        "pack.name=Приключения",
        "pack.description=Навигатор с картой, крюк-кошка, рюкзак и данжи",
        "item.adv:navigator.name=§bНавигатор",
        "item.adv:backpack.name=§6Рюкзак",
    ]

    def add_item(ident, img, lang_name=None, extra=None):
        img.save(os.path.join(ITEM_TEX, ident + ".png"))
        tex = "adv_" + ident
        textures[tex] = {"textures": f"textures/items/adv/{ident}"}
        write_json(os.path.join(items_dir, ident + ".json"), item_json("adv:" + ident, tex, extra=extra))

    add_item("navigator", icon_navigator())
    add_item("backpack", icon_backpack())

    js_grapple = []
    roman = ["I", "II", "III", "IV", "V"]
    for tier, rng, speed, fly, mat in GRAPPLE_TIERS:
        ident = f"grapple_{tier}"
        add_item(ident, icon_grapple(tier),
                 extra={"minecraft:cooldown": {"category": "adv_grapple", "duration": 0.2}})
        lang.append(f"item.adv:{ident}.name=§fКрюк-кошка {roman[tier - 1]}")
        js_grapple.append({"id": "adv:" + ident, "tier": tier, "range": rng, "speed": speed, "fly": fly})
        if tier == 1:
            write_json(os.path.join(rec_dir, "grapple_1.json"), shapeless("adv:grapple_1", [
                {"item": "minecraft:stick"},
                {"item": "minecraft:string"},
                {"tag": "minecraft:stone_tool_materials"},
            ], "adv:grapple_1"))
        else:
            item, count = mat
            write_json(os.path.join(rec_dir, f"{ident}.json"), shapeless(f"adv:{ident}", [
                {"item": f"adv:grapple_{tier - 1}"},
                {"item": item, "count": count},
            ], "adv:" + ident))

    write_json(os.path.join(rec_dir, "navigator.json"), shapeless("adv:navigator", [
        {"item": "minecraft:compass"},
        {"item": "minecraft:paper", "count": 2},
    ], "adv:navigator"))
    write_json(os.path.join(rec_dir, "backpack.json"), {
        "format_version": "1.20.10",
        "minecraft:recipe_shaped": {
            "description": {"identifier": "adv:backpack"},
            "tags": ["crafting_table"],
            "pattern": ["LSL", "LCL", "LLL"],
            "key": {"L": "minecraft:leather", "S": "minecraft:string", "C": "minecraft:chest"},
            "unlock": [{"item": "minecraft:leather"}],
            "result": {"item": "adv:backpack"},
        },
    })

    for kind in ("zoom_in", "zoom_out", "add_wp", "list", "settings", "waypoint", "death", "dungeon",
                 "teleport", "rename", "delete", "back"):
        ui_icon(kind).save(os.path.join(UI_TEX, kind + ".png"))

    write_json(os.path.join(RP, "textures", "item_texture.json"), {
        "resource_pack_name": "adventure",
        "texture_name": "atlas.items",
        "texture_data": textures,
    })

    texts = os.path.join(RP, "texts")
    os.makedirs(texts, exist_ok=True)
    body = "\n".join(lang) + "\n"
    for code in ("ru_RU", "en_US"):
        with open(os.path.join(texts, code + ".lang"), "w", encoding="utf-8") as f:
            f.write(body)
    write_json(os.path.join(texts, "languages.json"), ["ru_RU", "en_US"])

    terrain, markers = make_glyphs()
    make_map_ui()
    with open(os.path.join(BP, "scripts", "glyphs.js"), "w", encoding="utf-8") as f:
        f.write("// Сгенерировано tools/adv_generate.py — не редактировать вручную.\n")
        f.write("export const TERRAIN = " + json.dumps(terrain, ensure_ascii=True, indent=2) + ";\n")
        f.write("export const TERRAIN_NAMES = " + json.dumps({k: n for k, n, _ in TERRAIN}, ensure_ascii=False, indent=2) + ";\n")
        f.write("export const MARKERS = " + json.dumps(markers, ensure_ascii=True, indent=2) + ";\n")
        f.write("export const GRAPPLE_TIERS = " + json.dumps(js_grapple, indent=2) + ";\n")

    # пак-иконки и превью
    icon = Image.new("RGBA", (128, 128), (24, 34, 44, 255))
    icon.alpha_composite(icon_navigator().resize((128, 128), Image.NEAREST))
    icon.save(os.path.join(RP, "pack_icon.png"))
    icon.save(os.path.join(BP, "pack_icon.png"))
    preview = Image.new("RGBA", (16 * 8 * 6 + 8 * 7, 16 * 6 + 16 + 256 + 8), (40, 40, 48, 255))
    x = 8
    for name in ["navigator", "backpack"] + [f"grapple_{t}" for t in range(1, 6)]:
        ic = Image.open(os.path.join(ITEM_TEX, name + ".png")).resize((96, 96), Image.NEAREST)
        preview.alpha_composite(ic, (x, 8))
        x += 104
    glyphs = Image.open(os.path.join(RP, "font", f"glyph_{GLYPH_PAGE:02X}.png")).crop((0, 0, 256, 80))
    preview.alpha_composite(glyphs.resize((512, 160), Image.NEAREST), (8, 120))
    os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
    preview.save(os.path.join(ROOT, "docs", "adventure.png"))


if __name__ == "__main__":
    main()
