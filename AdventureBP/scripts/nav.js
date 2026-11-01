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
const MAX_WAYPOINTS = 30;
const MAX_DEATHS = 5;
const UI = "textures/ui/adv/";

// ---------------------------------------------------------------- настройки и точки

function getCfg(p) {
  return Object.assign({ zoom: 1, size: 1, mode: 0, players: true, mobs: true, wps: true }, getJson(p, "adv:navcfg", {}));
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

function surfaceCell(dim, x, z, py) {
  let b;
  try {
    b = dim.getTopmostBlock({ x, z });
  } catch {
    b = undefined;
  }
  if (!b) return TERRAIN.unknown[1];
  const dy = b.location.y - py;
  return TERRAIN[category(b.typeId)][dy > 4 ? 2 : dy < -4 ? 0 : 1];
}

function caveCell(dim, x, z, py) {
  const feet = getBlock(dim, { x, y: py, z });
  if (!feet) return TERRAIN.unknown[1];
  try {
    if (feet.isLiquid) return TERRAIN[category(feet.typeId)][1];
  } catch {}
  if (!isOpen(feet)) return TERRAIN[category(feet.typeId)][0]; // стена
  const below = getBlock(dim, { x, y: py - 1, z });
  if (below && !isOpen(below)) return TERRAIN.cave[2]; // пол
  const below2 = getBlock(dim, { x, y: py - 2, z });
  return below2 && !isOpen(below2) ? TERRAIN.cave[1] : TERRAIN.cave[0]; // ступень / провал
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

function renderMap(p, cfg) {
  const dim = p.dimension;
  const size = SIZES[cfg.size] ?? SIZES[1];
  const scale = ZOOMS[cfg.zoom] ?? 1;
  const c = V.floor(p.location);
  const hw = Math.floor(size.w / 2);
  const hh = Math.floor(size.h / 2);
  const cave = useCaveMode(p, cfg);

  const grid = [];
  for (let r = 0; r < size.h; r++) {
    const row = [];
    for (let col = 0; col < size.w; col++) {
      const x = c.x + (col - hw) * scale;
      const z = c.z + (r - hh) * scale;
      row.push(cave ? caveCell(dim, x, z, c.y) : surfaceCell(dim, x, z, c.y));
    }
    grid.push(row);
  }

  const put = (loc, ch) => {
    const col = Math.round((loc.x - c.x) / scale) + hw;
    const r = Math.round((loc.z - c.z) / scale) + hh;
    if (col >= 0 && col < size.w && r >= 0 && r < size.h) grid[r][col] = ch;
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
        put(e.location, e.matches({ families: ["monster"] }) ? MARKERS.hostile : MARKERS.passive);
      } catch {}
    }
  }
  if (cfg.wps) {
    for (const w of getWaypoints(p)) {
      if (w.dim !== dim.id) continue;
      put(w, w.kind === "death" ? MARKERS.death : w.kind === "dungeon" ? MARKERS.dungeon : MARKERS.waypoint);
    }
  }
  const others = [];
  if (cfg.players) {
    for (const o of world.getAllPlayers()) {
      if (o.id === p.id || o.dimension.id !== dim.id) continue;
      others.push(o);
      put(o.location, MARKERS.player);
    }
  }
  grid[hh][hw] = MARKERS[SELF[headingIndex(p)]];
  return { lines: grid.map((r) => r.join("")), cave, scale, others };
}

// ---------------------------------------------------------------- окна

export function openMap(p) {
  const cfg = getCfg(p);
  const m = renderMap(p, cfg);
  const c = V.floor(p.location);
  const head = `§7${c.x}, ${c.y}, ${c.z} §8| §7${COMPASS[headingIndex(p)]} §8| §71:${m.scale} §8| §7${m.cave ? "пещеры" : "поверхность"}`;
  const legend = [];
  if (cfg.players) legend.push(`${MARKERS.player}§r игроки`);
  if (cfg.mobs) legend.push(`${MARKERS.hostile}§r враги ${MARKERS.passive}§r мирные`);
  if (cfg.wps) legend.push(`${MARKERS.waypoint}§r точки ${MARKERS.death}§r смерть`);
  let near = "";
  if (m.others.length) {
    near = "\n§7Рядом: " + m.others
      .map((o) => `§b${o.name}§7 ${Math.round(V.dist(o.location, p.location))} бл.`)
      .join(", ");
  }
  const body = `${head}\n§r${m.lines.join("\n")}\n§r${legend.join("  ")}${near}`;

  const form = new ActionFormData()
    .title("§lНавигатор")
    .body(body)
    .button("Приблизить", UI + "zoom_in")
    .button("Отдалить", UI + "zoom_out")
    .button("Поставить вейпоинт", UI + "add_wp")
    .button("Список вейпоинтов", UI + "list")
    .button("Отображение", UI + "settings");
  showForm(form, p, (res) => {
    switch (res.selection) {
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

function openWaypointList(p) {
  const list = sortedWaypoints(p);
  const form = new ActionFormData().title("Вейпоинты");
  form.body(list.length ? "§7Нажми на точку, чтобы телепортироваться, переименовать или удалить её." : "§7Пока нет ни одной точки.");
  for (const w of list) {
    const color = w.kind === "death" ? "§4" : w.kind === "dungeon" ? "§6" : "§1";
    form.button(`${color}§l${w.name}§r\n§8${wpLine(p, w)}`, UI + (w.kind === "death" ? "death" : w.kind === "dungeon" ? "dungeon" : "waypoint"));
  }
  form.button("Назад к карте", UI + "back");
  showForm(form, p, (res) => {
    const w = list[res.selection];
    if (!w) return openMap(p);
    openWaypoint(p, w.id);
  });
}

function openWaypoint(p, id) {
  const w = getWaypoints(p).find((x) => x.id === id);
  if (!w) return openWaypointList(p);
  const form = new ActionFormData()
    .title(w.name)
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
        return openRename(p, w);
      case 2:
        setWaypoints(p, getWaypoints(p).filter((x) => x.id !== id));
        p.sendMessage(`§7Точка «${w.name}» удалена.`);
        return openWaypointList(p);
      default:
        return openWaypointList(p);
    }
  });
}

function openRename(p, w) {
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
    openWaypoint(p, w.id);
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
    .dropdown("Вид карты", MODES, { defaultValueIndex: cfg.mode })
    .dropdown("Размер карты", SIZES.map((s) => s.name), { defaultValueIndex: cfg.size })
    .toggle("Показывать игроков", { defaultValue: cfg.players })
    .toggle("Показывать мобов", { defaultValue: cfg.mobs })
    .toggle("Показывать вейпоинты и точки смерти", { defaultValue: cfg.wps })
    .submitButton("Применить");
  showForm(form, p, (res) => {
    const v = res.formValues ?? [];
    cfg.mode = Number(v[0] ?? cfg.mode);
    cfg.size = Number(v[1] ?? cfg.size);
    cfg.players = !!v[2];
    cfg.mobs = !!v[3];
    cfg.wps = !!v[4];
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
