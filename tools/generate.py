#!/usr/bin/env python3
"""Генерирует предметы, иконки, переводы и defs.js из tools/defs.py."""
import json
import math
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(__file__))
from defs import POWERS  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BP = os.path.join(ROOT, "AwakeningBP")
RP = os.path.join(ROOT, "AwakeningRP")
TEX_DIR = os.path.join(RP, "textures", "items", "aw")

GOLD = (255, 215, 60)


# ---------------------------------------------------------------- иконки

def shade(c, k):
    return tuple(max(0, min(255, int(v * k))) for v in c)


def finish(img, pal, ult):
    """Добавляет тёмный контур вокруг рисунка и золотые искры для ульты."""
    out = img.copy()
    px = img.load()
    opx = out.load()
    outline = shade(pal[2], 0.45) + (255,)
    for y in range(16):
        for x in range(16):
            if px[x, y][3]:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < 16 and 0 <= ny < 16 and px[nx, ny][3]:
                    opx[x, y] = outline
                    break
    if ult:
        for x, y in ((1, 1), (14, 1), (1, 14), (14, 14)):
            if not opx[x, y][3]:
                opx[x, y] = GOLD + (255,)
        for x, y in ((0, 1), (1, 0), (15, 14), (14, 15)):
            if not opx[x, y][3]:
                opx[x, y] = shade(GOLD, 0.7) + (255,)
    return out


def draw_shape(shape, pal):
    L, M, D = [c + (255,) for c in pal]
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    p = img.load()

    if shape == "ball":
        d.polygon([(7, 2), (12, 1), (10, 5)], fill=M)
        d.polygon([(4, 4), (8, 1), (8, 5)], fill=D)
        d.ellipse((3, 5, 12, 14), fill=M)
        d.ellipse((5, 7, 9, 11), fill=L)
        p[6, 8] = (255, 255, 255, 255)
    elif shape == "ring":
        d.ellipse((1, 1, 14, 14), outline=M, width=2)
        d.ellipse((3, 3, 12, 12), outline=D, width=1)
        for a in range(0, 360, 45):
            x = 7.5 + 7 * math.cos(math.radians(a))
            y = 7.5 + 7 * math.sin(math.radians(a))
            p[int(round(x)), int(round(y))] = L
        d.ellipse((6, 6, 9, 9), fill=L)
    elif shape == "dash":
        d.polygon([(7, 3), (14, 8), (7, 13), (9, 8)], fill=M)
        d.polygon([(9, 6), (12, 8), (9, 10)], fill=L)
        for y, x0, x1 in ((4, 1, 5), (8, 0, 7), (12, 1, 5)):
            d.line((x0, y, x1, y), fill=D)
            p[x1, y] = L
    elif shape == "cone":
        d.polygon([(1, 7), (14, 1), (14, 14), (1, 8)], fill=D)
        d.polygon([(3, 7), (13, 3), (13, 12), (3, 8)], fill=M)
        d.polygon([(5, 7), (12, 5), (12, 10), (5, 8)], fill=L)
        d.rectangle((0, 6, 2, 9), fill=D)
    elif shape == "meteor":
        d.line((1, 1, 9, 9), fill=D, width=3)
        d.line((2, 1, 9, 8), fill=M, width=1)
        d.ellipse((7, 7, 14, 14), fill=M)
        d.ellipse((8, 8, 11, 11), fill=L)
        p[12, 9] = D
        p[10, 12] = D
    elif shape == "shard":
        d.polygon([(13, 1), (15, 3), (5, 13), (2, 14), (3, 11)], fill=M)
        d.line((12, 3, 4, 11), fill=L)
        d.polygon([(5, 13), (2, 14), (3, 11)], fill=D)
    elif shape == "wall":
        d.rectangle((1, 3, 14, 14), fill=M)
        for y in (6, 9, 12):
            d.line((1, y, 14, y), fill=D)
        for y0, xs in ((3, (5, 10)), (6, (3, 8, 13)), (9, (5, 10)), (12, (3, 8, 13))):
            for x in xs:
                d.line((x, y0, x, y0 + 2), fill=D)
        for x in (2, 6, 11):
            p[x, 4] = L
            p[x + 1, 10] = L
    elif shape == "shield":
        d.polygon([(2, 2), (13, 2), (13, 8), (8, 14), (7, 14), (2, 8)], fill=M)
        d.polygon([(4, 4), (11, 4), (11, 8), (7, 12), (4, 8)], fill=L)
        d.line((7, 4, 7, 11), fill=D)
        d.line((4, 7, 11, 7), fill=D)
    elif shape == "snowflake":
        c = 7
        for a in range(0, 180, 60):
            dx = 6 * math.cos(math.radians(a))
            dy = 6 * math.sin(math.radians(a))
            d.line((c - dx + .5, c - dy + .5, c + dx + .5, c + dy + .5), fill=M, width=1)
        for a in range(0, 360, 60):
            x = c + 4 * math.cos(math.radians(a))
            y = c + 4 * math.sin(math.radians(a))
            d.ellipse((x - 1 + .5, y - 1 + .5, x + 1 + .5, y + 1 + .5), outline=L)
        d.rectangle((6, 6, 8, 8), fill=L)
        p[7, 7] = (255, 255, 255, 255)
    elif shape == "bolt":
        d.polygon([(9, 0), (3, 8), (7, 8), (5, 15), (12, 6), (8, 6), (11, 0)], fill=M)
        d.line((9, 1, 5, 7), fill=L)
        d.line((10, 7, 7, 12), fill=L)
    elif shape == "chain":
        pts = [(1, 3), (5, 7), (4, 9), (9, 11), (8, 13), (14, 14)]
        d.line(pts, fill=M, width=2)
        d.line(pts, fill=L, width=1)
        for x, y in ((1, 3), (8, 6), (14, 14)):
            d.ellipse((x - 1, y - 1, x + 1, y + 1), fill=D)
        d.line((8, 6, 5, 7), fill=M)
    elif shape == "aura":
        d.ellipse((0, 0, 15, 15), outline=D, width=1)
        d.ellipse((2, 2, 13, 13), outline=M, width=1)
        d.polygon([(8, 3), (5, 8), (7, 8), (6, 12), (10, 7), (8, 7), (9, 3)], fill=L)
    elif shape == "storm":
        d.ellipse((1, 1, 8, 6), fill=D)
        d.ellipse((5, 0, 14, 6), fill=D)
        d.ellipse((3, 2, 12, 7), fill=shade(pal[2], 1.4) + (255,))
        d.polygon([(5, 7), (3, 11), (5, 11), (4, 15), (8, 10), (6, 10), (7, 7)], fill=M)
        d.polygon([(11, 7), (9, 11), (11, 11), (10, 15), (14, 10), (12, 10), (13, 7)], fill=L)
    elif shape == "blink":
        d.ellipse((1, 4, 8, 11), outline=D, width=1)
        d.ellipse((3, 6, 6, 9), fill=M)
        d.line((8, 7, 12, 7), fill=M)
        d.line((8, 8, 12, 8), fill=M)
        d.polygon([(11, 4), (15, 7), (15, 8), (11, 11)], fill=L)
    elif shape == "mark":
        d.ellipse((2, 2, 13, 13), outline=M, width=2)
        d.line((7, 0, 7, 4), fill=L)
        d.line((7, 11, 7, 15), fill=L)
        d.line((0, 7, 4, 7), fill=L)
        d.line((11, 7, 15, 7), fill=L)
        d.rectangle((6, 6, 8, 8), fill=D)
        p[7, 7] = L
    elif shape == "dagger":
        d.polygon([(14, 1), (15, 2), (6, 11), (4, 9)], fill=L)
        d.line((14, 2, 5, 11), fill=M)
        d.line((3, 8, 7, 12), fill=D, width=2)
        d.line((1, 13, 4, 10), fill=D, width=2)
        p[1, 14] = M
    elif shape == "up":
        d.polygon([(7, 0), (13, 6), (10, 6), (10, 10), (5, 10), (5, 6), (2, 6)], fill=M)
        d.polygon([(7, 2), (10, 5), (5, 5)], fill=L)
        for y in (12, 14):
            d.line((4, y, 11, y), fill=D)
    elif shape == "flurry":
        for x0, y0, col in ((1, 9, D), (5, 5, M), (9, 1, L)):
            d.ellipse((x0, y0, x0 + 5, y0 + 5), outline=col, width=1)
            p[x0 + 2, y0 + 2] = col
            p[x0 + 3, y0 + 3] = col
        d.line((3, 14, 14, 3), fill=L)
    elif shape == "pull":
        d.ellipse((5, 5, 10, 10), fill=D)
        d.rectangle((7, 7, 8, 8), fill=L)
        for (x0, y0), (x1, y1) in (((0, 0), (4, 4)), ((15, 0), (11, 4)),
                                   ((0, 15), (4, 11)), ((15, 15), (11, 11))):
            d.line((x0, y0, x1, y1), fill=M)
            p[x1, y1] = L
            sx = 1 if x1 > x0 else -1
            sy = 1 if y1 > y0 else -1
            p[x1 - sx, y1] = L
            p[x1, y1 - sy] = L
    elif shape == "push":
        d.ellipse((5, 5, 10, 10), fill=M)
        d.rectangle((7, 7, 8, 8), fill=L)
        for (x0, y0), (x1, y1) in (((4, 4), (0, 0)), ((11, 4), (15, 0)),
                                   ((4, 11), (0, 15)), ((11, 11), (15, 15))):
            d.line((x0, y0, x1, y1), fill=M)
            sx = 1 if x1 > x0 else -1
            sy = 1 if y1 > y0 else -1
            p[x1, y1] = L
            p[x1 - sx, y1] = L
            p[x1, y1 - sy] = L
    elif shape == "float":
        d.ellipse((4, 1, 11, 8), fill=M)
        d.ellipse((5, 2, 8, 5), fill=L)
        for y, w in ((10, 6), (12, 4), (14, 2)):
            d.line((7.5 - w, y, 7.5 + w, y), fill=D)
    elif shape == "singularity":
        d.ellipse((0, 3, 15, 12), outline=M, width=1)
        d.ellipse((2, 4, 13, 11), outline=L, width=1)
        d.ellipse((4, 4, 11, 11), fill=(10, 0, 20, 255))
        d.ellipse((5, 5, 10, 10), outline=D)
    elif shape == "orb":
        d.ellipse((2, 2, 13, 13), fill=M)
        d.ellipse((3, 3, 12, 12), fill=D)
        d.ellipse((5, 5, 10, 10), fill=M)
        d.ellipse((6, 6, 9, 9), fill=L)
        p[4, 5] = (255, 255, 255, 255)
        p[5, 4] = (255, 255, 255, 255)
    elif shape == "oblivion":
        d.polygon([(8, 0), (13, 6), (9, 15), (3, 9), (5, 3)], fill=M)
        d.polygon([(8, 2), (11, 6), (8, 12), (6, 8)], fill=L)
        d.line((5, 3, 9, 15), fill=D)
    else:
        raise ValueError(shape)
    return img


def save_icon(name, shape, pal, ult=False):
    img = finish(draw_shape(shape, pal), pal, ult)
    img.save(os.path.join(TEX_DIR, name + ".png"))
    return img


# ---------------------------------------------------------------- JSON

def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


def item_json(identifier, icon, cooldown_cat=None, glint=False):
    comps = {
        "minecraft:icon": {"textures": {"default": icon}},
        "minecraft:max_stack_size": 1,
        "minecraft:hand_equipped": True,
        "minecraft:glint": glint,
    }
    if cooldown_cat:
        comps["minecraft:cooldown"] = {"category": cooldown_cat, "duration": 0.25}
    return {
        "format_version": "1.21.40",
        "minecraft:item": {
            "description": {
                "identifier": identifier,
                "menu_category": {"category": "equipment"},
            },
            "components": comps,
        },
    }


def main():
    os.makedirs(TEX_DIR, exist_ok=True)
    items_dir = os.path.join(BP, "items")
    os.makedirs(items_dir, exist_ok=True)
    for f in os.listdir(items_dir):
        os.remove(os.path.join(items_dir, f))

    textures = {}
    lang = [
        "pack.name=Пробуждение",
        "pack.description=Аналог The Awakening: силы, способности и прокачка",
        "item.aw:awakening_orb.name=§6Сфера Пробуждения",
        "item.aw:oblivion_shard.name=§5Осколок Забвения",
    ]

    gold_pal = [(255, 245, 170), (240, 180, 40), (120, 60, 10)]
    for ident, shape, pal in (("awakening_orb", "orb", gold_pal),
                              ("oblivion_shard", "oblivion",
                               [(225, 200, 255), (130, 70, 200), (40, 15, 80)])):
        save_icon(ident, shape, pal)
        tex = "aw_" + ident
        textures[tex] = {"textures": f"textures/items/aw/{ident}"}
        write_json(os.path.join(items_dir, ident + ".json"),
                   item_json("aw:" + ident, tex, glint=ident == "awakening_orb"))

    js_powers = {}
    for power in POWERS:
        js_abilities = []
        for ab in power["abilities"]:
            short = ab["id"].split(":")[1]
            tex = "aw_" + short
            save_icon(short, ab["shape"], power["palette"], ab["ult"])
            textures[tex] = {"textures": f"textures/items/aw/{short}"}
            write_json(os.path.join(items_dir, short + ".json"),
                       item_json(ab["id"], tex, cooldown_cat=tex, glint=ab["ult"]))
            lang.append(f"item.{ab['id']}.name={power['color']}{ab['name']}")
            js_abilities.append({
                "id": ab["id"], "index": ab["index"], "name": ab["name"],
                "desc": ab["desc"], "cd": ab["cd"], "unlock": ab["unlock"],
                "ult": ab["ult"], "icon": f"textures/items/aw/{short}",
                "cooldownCategory": tex,
            })
        js_powers[power["id"]] = {
            "id": power["id"], "name": power["name"], "color": power["color"],
            "passive": power["passive"], "abilities": js_abilities,
        }

    write_json(os.path.join(RP, "textures", "item_texture.json"), {
        "resource_pack_name": "awakening",
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

    with open(os.path.join(BP, "scripts", "defs.js"), "w", encoding="utf-8") as f:
        f.write("// Сгенерировано tools/generate.py — не редактировать вручную.\n")
        f.write("export const POWERS = ")
        json.dump(js_powers, f, ensure_ascii=False, indent=2)
        f.write(";\n")

    make_pack_icons(gold_pal)
    make_preview()


def make_pack_icons(pal):
    big = finish(draw_shape("orb", pal), pal, True).resize((128, 128), Image.NEAREST)
    bg = Image.new("RGBA", (128, 128), (30, 14, 50, 255))
    bg.alpha_composite(big)
    bg.save(os.path.join(RP, "pack_icon.png"))
    bg.save(os.path.join(BP, "pack_icon.png"))


def make_preview():
    """Сводная картинка всех иконок (для README)."""
    scale, pad = 6, 8
    cols = 5
    rows = len(POWERS) + 1
    w = cols * (16 * scale + pad) + pad
    h = rows * (16 * scale + pad) + pad
    sheet = Image.new("RGBA", (w, h), (40, 40, 48, 255))
    names = [["awakening_orb", "oblivion_shard"]]
    names += [[a["id"].split(":")[1] for a in p["abilities"]] for p in POWERS]
    for r, row in enumerate(names):
        for c, n in enumerate(row):
            ic = Image.open(os.path.join(TEX_DIR, n + ".png")).resize((16 * scale, 16 * scale), Image.NEAREST)
            sheet.alpha_composite(ic, (pad + c * (16 * scale + pad), pad + r * (16 * scale + pad)))
    os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
    sheet.save(os.path.join(ROOT, "docs", "icons.png"))


if __name__ == "__main__":
    main()
