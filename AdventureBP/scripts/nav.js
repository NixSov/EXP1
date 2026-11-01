// Навигатор: карта местности в окне, вейпоинты, точки смерти.
import { world, system } from "@minecraft/server";
import { ActionFormData, ModalFormData } from "@minecraft/server-ui";
import { TERRAIN, MARKERS } from "./glyphs.js";
import { V, getBlock, getJson, setJson, dimName, showForm, sound, particle, isValid } from "./util.js";

const ZOOMS = [1, 2, 4, 8, 16];
const SIZES = [
  { name: "Малая", w: 15, h: 11 },
  { name: "Средняя", w: 19, h: 13 },
  { name: "Большая", w: 23, h: 15 },
];
const MODES = ["Авто", "Поверхность", "Пещеры"];
const VIEWS = ["Картинка (новый)", "Символы (простой)"];
const MAX_WAYPOINTS = 30;
const MAX_DEATHS = 5;
const UI = "textures/ui/adv/";

// ---------------------------------------------------------------- настройки и точки

function getCfg(p) {
  return Object.assign({ zoom: 1, size: 1, mode: 0, view: 0, players: true, mobs: true, wps: true }, getJson(p, "adv:navcfg", {}));
}

function setCfg(p, cfg) {
  setJson(p, "adv:navcfg", cfg);
}

export function getWaypoints(p) {
  return getJson(p, "adv:wp", []);
}

function setWaypoints(p, list) {
  setJson(p, "adv:wp", list);
}

export function addWaypoint(p, wp) {
  const list = getWaypoints(p);
  if (wp.kind === "dungeon" && list.some((w) => w.kind === "dungeon" && w.key === wp.key)) return false;
  list.push({ id: Date.now() + Math.floor(Math.random() * 1000), ...wp });
  if (wp.kind === "death") {
    const deaths = list.filter((w) => w.kind === "death");
    while (deaths.length > MAX_DEATHS) {
      const old = deaths.shift();
      list.splice(list.indexOf(old), 1);
    }
  }
  setWaypoints(p, list);
  return true;
}

// ---------------------------------------------------------------- местность

const categoryCache = new Map();

function category(typeId) {
  let c = categoryCache.get(typeId);
  if (c) return c;
  const id = typeId.replace("minecraft:", "");
  if (/water|bubble_column|kelp|seagrass|coral/.test(id)) c = "water";
  else if (/lava/.test(id)) c = "lava";
  else if (/leaves|vine|azalea|mushroom_block|cactus|bamboo|pumpkin|melon|mangrove_roots|moss_carpet/.test(id)) c = "foliage";
  else if (/^(grass_block|moss_block|short_grass|tall_grass|fern|large_fern|.*flower.*|.*tulip|poppy|dandelion|.*orchid|allium|azure_bluet|oxeye_daisy|cornflower|lily_of_the_valley|sweet_berry_bush|.*sapling|wheat|carrots|potatoes|beetroot|pink_petals)$/.test(id)) c = "grass";
  else if (/snow|ice/.test(id)) c = "snow";
  else if (/red_sand|terracotta/.test(id)) c = "clay";
  else if (/sand|sandstone/.test(id)) c = "sand";
  else if (/^(dirt|coarse_dirt|podzol|mud|rooted_dirt|farmland|dirt_path|grass_path|clay|mycelium|packed_mud|muddy_mangrove_roots)$/.test(id)) c = "dirt";
  else if (/planks|_log|_wood|stem|hyphae|fence|door|crafting_table|chest|barrel|bookshelf|ladder|_slab$|_stairs$/.test(id) && !/stone|brick|deepslate|blackstone|quartz|purpur|copper|tuff|prismarine|sandstone/.test(id)) c = "wood";
  else if (/netherrack|nether|crimson|warped|soul|magma|glowstone|basalt|blackstone|shroomlight/.test(id)) c = "nether";
  else if (/end_stone|purpur|chorus/.test(id)) c = "end";
  else if (/obsidian|bedrock|sculk|reinforced/.test(id)) c = "dark";
  else c = "stone";
  categoryCache.set(typeId, c);
  return c;
}

function isOpen(block) {
  if (!block) return false;
  try {
    return block.isAir || /short_grass|tall_grass|fern|flower|torch|snow_layer|vine|rail|carpet|button|lever|sign|banner/.test(block.typeId);
  } catch {
    return false;
  }
}

// Поиск верхнего блока дорогой, поэтому результаты держим 10 секунд.
const topCache = new Map(); // "dim|x|z" -> { y, cat, tick }
const TOP_TTL = 200;

function chunkLoaded(dim, x, z, py, chunkCache) {
  const key = (x >> 4) + "," + (z >> 4);
  let ok = chunkCache.get(key);
  if (ok === undefined) {
    ok = !!getBlock(dim, { x, y: py, z });
    chunkCache.set(key, ok);
  }
  return ok;
}

/** Верхний блок колонки: { y, cat } или undefined. Снежный слой поверх травы считается снегом. */
function surfaceSample(dim, x, z, py, chunkCache) {
  const key = dim.id + "|" + x + "|" + z;
  const now = system.currentTick;
  let t = topCache.get(key);
  if (!t || now - t.tick > TOP_TTL || now < t.tick) {
    if (!chunkLoaded(dim, x, z, py, chunkCache)) return undefined;
    let b;
    try {
      b = dim.getTopmostBlock({ x, z });
    } catch {
      b = undefined;
    }
    if (!b) return undefined;
    let cat = category(b.typeId);
    const above = getBlock(dim, { x, y: b.location.y + 1, z });
    if (above && /snow_layer|powder_snow/.test(above.typeId)) cat = "snow";
    t = { y: b.location.y, cat, tick: now };
    topCache.set(key, t);
    if (topCache.size > 20000) topCache.clear();
  }
  return t;
}

function caveCell(dim, x, z, py, chunkCache) {
  if (!chunkLoaded(dim, x, z, py, chunkCache)) return "unknown:1";
  const feet = getBlock(dim, { x, y: py, z });
  if (!feet) return "unknown:1";
  try {
    if (feet.isLiquid) return category(feet.typeId) + ":1";
  } catch {}
  if (!isOpen(feet)) return category(feet.typeId) + ":0"; // стена
  const below = getBlock(dim, { x, y: py - 1, z });
  if (below && !isOpen(below)) return "cave:2"; // пол
  const below2 = getBlock(dim, { x, y: py - 2, z });
  return below2 && !isOpen(below2) ? "cave:1" : "cave:0"; // ступень / провал
}

function useCaveMode(p, cfg) {
  if (cfg.mode === 1) return false;
  if (cfg.mode === 2) return true;
  if (p.dimension.id.endsWith("nether")) return true;
  try {
    const loc = V.floor(p.location);
    const top = p.dimension.getTopmostBlock({ x: loc.x, z: loc.z });
    return !!top && top.location.y > loc.y + 3 && category(top.typeId) !== "foliage";
  } catch {
    return false;
  }
}

function headingIndex(p) {
  const yaw = p.getRotation().y;
  const compass = (((yaw + 180) % 360) + 360) % 360; // 0 — север
  return Math.round(compass / 45) % 8;
}

const SELF = ["self_n", "self_ne", "self_e", "self_se", "self_s", "self_sw", "self_w", "self_nw"];
const COMPASS = ["С", "СВ", "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ"];

// ---------------------------------------------------------------- отрисовка

// Окно с картинками (JSON UI): сетка фиксированного размера
const PIC_W = 21;
const PIC_H = 15;
const MAP_TEX = "textures/ui/adv/map/";

/** Клетка карты -> символ (простой вид). */
function keyToGlyph(key) {
  const [a, b] = key.split(":");
  return a === "m" ? MARKERS[b] : TERRAIN[a][Number(b)];
}

/** Клетка карты -> картинка (новый вид). */
function keyToTexture(key) {
  const [a, b] = key.split(":");
  return MAP_TEX + (a === "m" ? "m_" + b : a + "_" + b);
}

/**
 * Отрисовка по строке за тик — чтобы игра не прерывала долгий скрипт.
 * Тени как у ванильной карты: клетка выше северной соседки светлее, ниже — темнее.
 */
function* renderMap(p, cfg, out) {
  const dim = p.dimension;
  const pic = cfg.view === 0;
  const size = pic ? { w: PIC_W, h: PIC_H } : SIZES[cfg.size] ?? SIZES[1];
  const scale = ZOOMS[cfg.zoom] ?? 1;
  const c = V.floor(p.location);
  const hw = Math.floor(size.w / 2);
  const hh = Math.floor(size.h / 2);
  const cave = useCaveMode(p, cfg);

  const chunkCache = new Map();
  const grid = [];
  let northRow = [];
  for (let r = -1; r < size.h; r++) {
    const row = [];
    const samples = [];
    for (let col = 0; col < size.w; col++) {
      const x = c.x + (col - hw) * scale;
      const z = c.z + (r - hh) * scale;
      if (cave) {
        row.push(r < 0 ? undefined : caveCell(dim, x, z, c.y, chunkCache));
        continue;
      }
      const t = surfaceSample(dim, x, z, c.y, chunkCache);
      if (r < 0) {
        row.push(t);
        continue;
      }
      if (!t) {
        row.push("unknown:1");
        continue;
      }
      const n = northRow[col];
      let shade = 1;
      if (t.cat !== "water" && t.cat !== "lava" && n) shade = t.y > n.y ? 2 : t.y < n.y ? 0 : 1;
      row.push(t.cat + ":" + shade);
      samples[col] = t;
    }
    if (r < 0) {
      northRow = row;
    } else {
      northRow = samples;
      grid.push(row);
    }
    yield;
    if (!isValid(p)) return;
  }

  const put = (loc, kind) => {
    const col = Math.round((loc.x - c.x) / scale) + hw;
    const r = Math.round((loc.z - c.z) / scale) + hh;
    if (col >= 0 && col < size.w && r >= 0 && r < size.h) grid[r][col] = "m:" + kind;
  };
  const radius = Math.max(hw, hh) * scale + scale;

  if (cfg.mobs) {
    let mobs = [];
    try {
      mobs = dim.getEntities({ location: p.location, maxDistance: radius, excludeTypes: ["minecraft:player", "minecraft:item", "minecraft:xp_orb"] });
    } catch {}
    for (const e of mobs) {
      try {
        if (!e.getComponent("minecraft:health")) continue;
        put(e.location, e.matches({ families: ["monster"] }) ? "hostile" : "passive");
      } catch {}
    }
  }
  if (cfg.wps) {
    for (const w of getWaypoints(p)) {
      if (w.dim !== dim.id) continue;
      put(w, w.kind === "death" ? "death" : w.kind === "dungeon" ? "dungeon" : "waypoint");
    }
  }
  const others = [];
  if (cfg.players) {
    for (const o of world.getAllPlayers()) {
      if (o.id === p.id || o.dimension.id !== dim.id) continue;
      others.push(o);
      put(o.location, "player");
    }
  }
  grid[hh][hw] = "m:" + SELF[headingIndex(p)];
  Object.assign(out, { grid, cave, scale, others, pic });
}

const rendering = new Set();

export function openMap(p) {
  if (rendering.has(p.id)) return;
  rendering.add(p.id);
  const cfg = getCfg(p);
  const m = {};
  system.runJob((function* () {
    try {
      yield* renderMap(p, cfg, m);
      if (isValid(p)) showMap(p, cfg, m);
    } catch (e) {
      // карта не должна «ломаться» навсегда: сбрасываем масштаб и сообщаем ошибку
      cfg.zoom = 0;
      setCfg(p, cfg);
      if (isValid(p)) p.sendMessage(`§cОшибка карты (пришли это разработчику): §7${e}`);
      console.warn("[adventure] map: " + e);
    } finally {
      rendering.delete(p.id);
    }
  })());
}

// Метка в заголовке: по ней ресурс-пак (ui/server_form.json) рисует окно карты картинками.
export const MAP_FORM_FLAG = "§a§d§v§r";
// Метка для обычных меню навигатора в том же оформлении.
export const MENU_FORM_FLAG = "§a§d§m§r";
const ACTIONS = [
  ["Приблизить", "zoom_in"],
  ["Отдалить", "zoom_out"],
  ["Вейпоинт", "add_wp"],
  ["Список", "list"],
  ["Вид", "settings"],
];

function showMap(p, cfg, m) {
  const c = V.floor(p.location);
  const head = `§7${c.x}, ${c.y}, ${c.z}  §8|  §7${COMPASS[headingIndex(p)]}  §8|  §71:${m.scale}  §8|  §7${m.cave ? "пещеры" : "поверхность"}`;
  let near = "";
  if (m.others.length) {
    near = "\n§7Рядом: " + m.others
      .map((o) => `§b${o.name}§7 ${Math.round(V.dist(o.location, p.location))} бл.`)
      .join(", ");
  }

  const form = new ActionFormData();
  let offset = 0;
  if (m.pic) {
    form.title(MAP_FORM_FLAG + "§lНавигатор").body(head + near);
    for (const row of m.grid) for (const key of row) form.button("", keyToTexture(key));
    offset = PIC_W * PIC_H;
  } else {
    const legend = [];
    if (cfg.players) legend.push(`${MARKERS.player}§r игроки`);
    if (cfg.mobs) legend.push(`${MARKERS.hostile}§r враги ${MARKERS.passive}§r мирные`);
    if (cfg.wps) legend.push(`${MARKERS.waypoint}§r точки ${MARKERS.death}§r смерть`);
    const lines = m.grid.map((row) => row.map(keyToGlyph).join(""));
    form.title("§lНавигатор").body(`${head}\n§r${lines.join("\n")}\n§r${legend.join("  ")}${near}`);
  }
  for (const [text, icon] of ACTIONS) form.button(text, UI + icon);

  showForm(form, p, (res) => {
    const sel = res.selection - offset;
    switch (sel) {
      case 0:
        cfg.zoom = Math.max(0, cfg.zoom - 1);
        setCfg(p, cfg);
        return openMap(p);
      case 1:
        cfg.zoom = Math.min(ZOOMS.length - 1, cfg.zoom + 1);
        setCfg(p, cfg);
        return openMap(p);
      case 2:
        return openAddWaypoint(p);
      case 3:
        return openWaypointList(p);
      case 4:
        return openDisplay(p);
      default:
        return openMap(p); // нажата клетка карты
    }
  });
}

function openAddWaypoint(p) {
  const n = getWaypoints(p).filter((w) => w.kind === "wp").length + 1;
  const loc = V.floor(p.location);
  const form = new ModalFormData()
    .title("Новый вейпоинт")
    .textField(`Координаты: ${loc.x}, ${loc.y}, ${loc.z}\nНазвание:`, "Название точки", { defaultValue: `Точка ${n}` })
    .submitButton("Сохранить");
  showForm(form, p, (res) => {
    if (getWaypoints(p).filter((w) => w.kind === "wp").length >= MAX_WAYPOINTS) {
      p.sendMessage(`§cМаксимум ${MAX_WAYPOINTS} вейпоинтов. Удали ненужные.`);
      return openMap(p);
    }
    const name = String(res.formValues?.[0] ?? "").trim().slice(0, 32) || `Точка ${n}`;
    addWaypoint(p, { kind: "wp", name, x: loc.x, y: loc.y, z: loc.z, dim: p.dimension.id });
    p.sendMessage(`§aВейпоинт «${name}» сохранён.`);
    sound(p.dimension, "random.orb", p.location, 1.4);
    openMap(p);
  });
}

function sortedWaypoints(p) {
  const order = { wp: 0, dungeon: 1, death: 2 };
  return getWaypoints(p).sort((a, b) => (order[a.kind] - order[b.kind]) || (a.id - b.id));
}

function wpLine(p, w) {
  const same = w.dim === p.dimension.id;
  const dist = same ? `${Math.round(V.dist(w, p.location))} бл.` : dimName(w.dim);
  return `${dist} · ${w.x}, ${w.y}, ${w.z}`;
}

// Прокрутка в окнах форм на телефоне ненадёжна, поэтому список разбит на страницы.
const PAGE_SIZE = 3;

function openWaypointList(p, page = 0) {
  const list = sortedWaypoints(p);
  const pages = Math.max(1, Math.ceil(list.length / PAGE_SIZE));
  page = Math.max(0, Math.min(page, pages - 1));
  const shown = list.slice(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE);
  const form = new ActionFormData().title(MENU_FORM_FLAG + "§lВейпоинты");
  form.body(list.length
    ? `§7Страница ${page + 1} из ${pages} · всего точек: ${list.length}`
    : "§7Пока нет ни одной точки.");
  for (const w of shown) {
    const color = w.kind === "death" ? "§c" : w.kind === "dungeon" ? "§6" : "§e";
    form.button(`${color}${w.name}§r\n§7${wpLine(p, w)}`, UI + (w.kind === "death" ? "death" : w.kind === "dungeon" ? "dungeon" : "waypoint"));
  }
  const hasNext = page < pages - 1;
  if (hasNext) form.button("Следующая страница", UI + "next");
  form.button(page > 0 ? "Предыдущая страница" : "Назад к карте", UI + "back");
  showForm(form, p, (res) => {
    const sel = res.selection;
    if (sel < shown.length) return openWaypoint(p, shown[sel].id, page);
    if (hasNext && sel === shown.length) return openWaypointList(p, page + 1);
    if (page > 0) return openWaypointList(p, page - 1);
    openMap(p);
  });
}

function openWaypoint(p, id, page = 0) {
  const w = getWaypoints(p).find((x) => x.id === id);
  if (!w) return openWaypointList(p, page);
  const form = new ActionFormData()
    .title(MENU_FORM_FLAG + "§l" + w.name)
    .body(`§7${dimName(w.dim)}\n§f${w.x}, ${w.y}, ${w.z}\n§7${wpLine(p, w)}`)
    .button("Телепортироваться", UI + "teleport")
    .button("Переименовать", UI + "rename")
    .button("Удалить", UI + "delete")
    .button("Назад", UI + "back");
  showForm(form, p, (res) => {
    switch (res.selection) {
      case 0:
        return teleportTo(p, w);
      case 1:
        return openRename(p, w, page);
      case 2:
        setWaypoints(p, getWaypoints(p).filter((x) => x.id !== id));
        p.sendMessage(`§7Точка «${w.name}» удалена.`);
        return openWaypointList(p, page);
      default:
        return openWaypointList(p, page);
    }
  });
}

function openRename(p, w, page = 0) {
  const form = new ModalFormData()
    .title("Переименовать")
    .textField("Новое название:", "Название", { defaultValue: w.name })
    .submitButton("Готово");
  showForm(form, p, (res) => {
    const name = String(res.formValues?.[0] ?? "").trim().slice(0, 32);
    if (name) {
      const list = getWaypoints(p);
      const item = list.find((x) => x.id === w.id);
      if (item) item.name = name;
      setWaypoints(p, list);
    }
    openWaypoint(p, w.id, page);
  });
}

function teleportTo(p, w) {
  let dim;
  try {
    dim = world.getDimension(w.dim);
  } catch {
    return;
  }
  particle(p.dimension, "minecraft:portal_reverse_particle", p.location);
  try {
    p.teleport({ x: w.x + 0.5, y: w.y, z: w.z + 0.5 }, { dimension: dim });
  } catch (e) {
    p.sendMessage("§cНе удалось телепортироваться: " + e);
    return;
  }
  system.runTimeout(() => {
    if (!isValid(p)) return;
    sound(p.dimension, "mob.endermen.portal", p.location);
  }, 2);
}

function openDisplay(p) {
  const cfg = getCfg(p);
  const form = new ModalFormData()
    .title("Отображение")
    .dropdown("Вид окна", VIEWS, { defaultValueIndex: cfg.view })
    .dropdown("Вид карты", MODES, { defaultValueIndex: cfg.mode })
    .dropdown("Размер карты (для простого вида)", SIZES.map((s) => s.name), { defaultValueIndex: cfg.size })
    .toggle("Показывать игроков", { defaultValue: cfg.players })
    .toggle("Показывать мобов", { defaultValue: cfg.mobs })
    .toggle("Показывать вейпоинты и точки смерти", { defaultValue: cfg.wps })
    .submitButton("Применить");
  showForm(form, p, (res) => {
    const v = res.formValues ?? [];
    cfg.view = Number(v[0] ?? cfg.view);
    cfg.mode = Number(v[1] ?? cfg.mode);
    cfg.size = Number(v[2] ?? cfg.size);
    cfg.players = !!v[3];
    cfg.mobs = !!v[4];
    cfg.wps = !!v[5];
    setCfg(p, cfg);
    openMap(p);
  });
}

// ---------------------------------------------------------------- точки смерти

world.afterEvents.entityDie.subscribe((ev) => {
  const p = ev.deadEntity;
  try {
    if (p.typeId !== "minecraft:player") return;
    const loc = V.floor(p.location);
    const n = (Number(p.getDynamicProperty("adv:deaths")) || 0) + 1;
    p.setDynamicProperty("adv:deaths", n);
    addWaypoint(p, { kind: "death", name: `Смерть №${n}`, x: loc.x, y: loc.y, z: loc.z, dim: p.dimension.id });
  } catch {}
});

world.afterEvents.playerSpawn.subscribe((ev) => {
  if (ev.initialSpawn) return;
  const p = ev.player;
  const last = getWaypoints(p).filter((w) => w.kind === "death").pop();
  if (last) {
    system.runTimeout(() => {
      if (isValid(p)) p.sendMessage(`§7Точка смерти сохранена в навигаторе: §f${last.x}, ${last.y}, ${last.z}`);
    }, 20);
  }
});
