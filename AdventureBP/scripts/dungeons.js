// Данжи: три вида подземелий, которые появляются в мире рядом с игроками.
//   • Крипта Забытых      — каменные залы, скелеты и зомби, стрелы из стен; босс «Хранитель Крипты».
//   • Ледяной Склеп       — лёд и снег, зимогоры, ловушки с рыхлым снегом; босс «Ледяной Король».
//   • Пылающая Кузня      — глубоко под землёй, чернокамень и магма, ифриты; босс «Мастер Кузни».
// Каждый данж: 9 залов (3×3), соединённых коридорами, вход-лестница с поверхности,
// залы с мобами, ловушками и сундуками, зал босса с наградой.
import { world, system, ItemStack } from "@minecraft/server";
import { V, getBlock, getJson, setJson, particle, sound, isValid } from "./util.js";
import { addWaypoint } from "./nav.js";

const CELL = 176; // размер ячейки сетки мира, в каждой может быть один данж
const CHANCE = 0.5;
const BUILD_DISTANCE = 36;
const ROOM = 9; // зал с толщиной стен
const GAP = 4; // длина коридора между залами
const PITCH = ROOM + GAP;
const SIZE = 3 * ROOM + 2 * GAP; // 35
const HEIGHT = 6; // пол y0, потолок y0+HEIGHT

// ---------------------------------------------------------------- темы

const THEMES = {
  crypt: {
    name: "Крипта Забытых",
    color: "§7",
    depth: 15,
    wall: [["stone_bricks", 6], ["mossy_stone_bricks", 3], ["cracked_stone_bricks", 2]],
    floor: [["stone_bricks", 4], ["cobblestone", 2], ["mossy_cobblestone", 2]],
    ceiling: [["stone_bricks", 3], ["mossy_stone_bricks", 1]],
    light: "minecraft:soul_lantern",
    lightOnFloor: true,
    decor: [["cobweb", 3], ["bone_block", 1]],
    surface: "mossy_stone_bricks",
    mobs: [["minecraft:zombie", 3], ["minecraft:skeleton", 3], ["minecraft:husk", 1]],
    elite: "minecraft:skeleton",
    boss: { type: "minecraft:zombie", name: "§5Хранитель Крипты", hp: 9, minion: "minecraft:skeleton" },
    loot: "chests/simple_dungeon",
    bossLoot: "chests/stronghold_corridor",
    trap: "arrows",
  },
  frost: {
    name: "Ледяной Склеп",
    color: "§b",
    depth: 15,
    wall: [["packed_ice", 6], ["blue_ice", 2], ["snow", 2]],
    floor: [["packed_ice", 3], ["snow", 3]],
    ceiling: [["packed_ice", 3], ["blue_ice", 1]],
    light: "minecraft:sea_lantern",
    lightOnFloor: false,
    decor: [["snow_layer", 3], ["ice", 1]],
    surface: "packed_ice",
    mobs: [["minecraft:stray", 4], ["minecraft:zombie", 1], ["minecraft:skeleton", 1]],
    elite: "minecraft:stray",
    boss: { type: "minecraft:stray", name: "§bЛедяной Король", hp: 9, minion: "minecraft:stray" },
    loot: "chests/abandoned_mineshaft",
    bossLoot: "chests/igloo_chest",
    trap: "powder_snow",
  },
  forge: {
    name: "Пылающая Кузня",
    color: "§6",
    depth: 26,
    wall: [["blackstone", 4], ["polished_blackstone_bricks", 4], ["cracked_polished_blackstone_bricks", 2], ["gilded_blackstone", 1]],
    floor: [["polished_blackstone", 5], ["magma", 1]],
    ceiling: [["blackstone", 3], ["polished_blackstone_bricks", 1]],
    light: "minecraft:shroomlight",
    lightOnFloor: false,
    decor: [["chain", 1]],
    surface: "polished_blackstone_bricks",
    mobs: [["minecraft:wither_skeleton", 2], ["minecraft:blaze", 2], ["minecraft:magma_cube", 1]],
    elite: "minecraft:wither_skeleton",
    boss: { type: "minecraft:wither_skeleton", name: "§6Мастер Кузни", hp: 11, minion: "minecraft:blaze" },
    loot: "chests/ruined_portal",
    bossLoot: "chests/bastion_treasure",
    trap: "fire",
  },
};
const THEME_KEYS = Object.keys(THEMES);

// Дополнительный лут: [предмет, мин, макс, вес]
const EXTRA_LOOT = [
  ["minecraft:iron_ingot", 2, 6, 6],
  ["minecraft:gold_ingot", 2, 5, 5],
  ["minecraft:diamond", 1, 2, 2],
  ["minecraft:emerald", 1, 4, 3],
  ["minecraft:golden_apple", 1, 1, 2],
  ["minecraft:ender_pearl", 1, 3, 3],
  ["minecraft:string", 2, 6, 4],
  ["minecraft:leather", 2, 5, 3],
  ["minecraft:experience_bottle", 2, 6, 3],
];
const BOSS_EXTRA = [
  ["minecraft:diamond", 2, 5, 4],
  ["minecraft:netherite_scrap", 1, 1, 1],
  ["minecraft:enchanted_golden_apple", 1, 1, 1],
  ["minecraft:totem_of_undying", 1, 1, 1],
  ["minecraft:gold_block", 1, 2, 2],
];

// ---------------------------------------------------------------- случайность

function hash(x, z, salt = 0) {
  let h = (x * 374761393 + z * 668265263 + salt * 2147483647) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}

function rng(seed) {
  let s = Math.floor(seed * 4294967296) >>> 0 || 1;
  return () => {
    s ^= s << 13;
    s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5;
    s >>>= 0;
    return s / 4294967296;
  };
}

function pick(list, r) {
  const total = list.reduce((s, it) => s + it[it.length - 1], 0);
  let v = r() * total;
  for (const it of list) {
    v -= it[it.length - 1];
    if (v <= 0) return it;
  }
  return list[0];
}

// ---------------------------------------------------------------- состояние

function siteKey(cx, cz) {
  return `adv:dg:${cx}_${cz}`;
}

function siteFor(cx, cz) {
  if (Math.abs(cx) + Math.abs(cz) === 0) return undefined; // не у самого спавна
  if (hash(cx, cz, 1) > CHANCE) return undefined;
  const x = cx * CELL + 30 + Math.floor(hash(cx, cz, 2) * (CELL - 60));
  const z = cz * CELL + 30 + Math.floor(hash(cx, cz, 3) * (CELL - 60));
  const theme = THEME_KEYS[Math.floor(hash(cx, cz, 4) * THEME_KEYS.length)];
  return { key: siteKey(cx, cz), x, z, theme, seed: hash(cx, cz, 5) };
}

const building = new Set();
const sites = new Map(); // key -> запись построенного данжа (кэш)

function loadSite(key) {
  if (sites.has(key)) return sites.get(key);
  const s = getJson(world, key, undefined);
  if (s && s.state === "built") sites.set(key, s);
  return s;
}

function saveSite(s) {
  setJson(world, s.key, s);
  if (s.state === "built") sites.set(s.key, s);
}

function rememberBuiltKeys() {
  return getJson(world, "adv:dg_index", []);
}

function indexSite(key) {
  const list = rememberBuiltKeys();
  if (!list.includes(key)) {
    list.push(key);
    setJson(world, "adv:dg_index", list);
  }
}

// ---------------------------------------------------------------- строительство

function* place(dim, loc, type) {
  const b = getBlock(dim, loc);
  if (!b) return;
  try {
    if (typeof type === "string") b.setType(type.includes(":") ? type : "minecraft:" + type);
    else b.setPermutation(type);
  } catch {}
}

function layout(r) {
  // случайное остовное дерево по сетке 3×3 + одно лишнее ребро для петли
  const edges = [];
  const seen = new Set(["1,0"]);
  const stack = [[1, 0]];
  while (stack.length) {
    const [i, j] = stack[stack.length - 1];
    const next = [[i + 1, j], [i - 1, j], [i, j + 1], [i, j - 1]]
      .filter(([a, b]) => a >= 0 && a < 3 && b >= 0 && b < 3 && !seen.has(`${a},${b}`));
    if (!next.length) {
      stack.pop();
      continue;
    }
    const [a, b] = next[Math.floor(r() * next.length)];
    seen.add(`${a},${b}`);
    edges.push([[i, j], [a, b]]);
    stack.push([a, b]);
  }
  const all = [];
  for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) {
    if (i < 2) all.push([[i, j], [i + 1, j]]);
    if (j < 2) all.push([[i, j], [i, j + 1]]);
  }
  const has = (e) => edges.some(([p, q]) => (p + "" === e[0] + "" && q + "" === e[1] + "") || (p + "" === e[1] + "" && q + "" === e[0] + ""));
  const extra = all.filter((e) => !has(e));
  if (extra.length) edges.push(extra[Math.floor(r() * extra.length)]);
  return edges;
}

function roomKinds(r) {
  // вход (1,0) и босс (1,2) фиксированы, остальным раздаём роли
  const others = [];
  for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) if (!(i === 1 && (j === 0 || j === 2))) others.push([i, j]);
  const kinds = ["loot", "loot", "trap", "mobs", "mobs", "mobs", "elite"];
  for (let k = kinds.length - 1; k > 0; k--) {
    const m = Math.floor(r() * (k + 1));
    [kinds[k], kinds[m]] = [kinds[m], kinds[k]];
  }
  const map = { "1,0": "entrance", "1,2": "boss" };
  others.forEach(([i, j], k) => (map[`${i},${j}`] = kinds[k]));
  return map;
}

function* buildDungeon(site, dim, surfaceY) {
  const t = THEMES[site.theme];
  const r = rng(site.seed);
  const y0 = Math.max(-52, surfaceY - t.depth);
  const ox = site.x - Math.floor(SIZE / 2);
  const oz = site.z - Math.floor(SIZE / 2);
  const mat = (list) => pick(list, r)[0];

  const box = function* (x1, y1, z1, x2, y2, z2) {
    for (let x = x1; x <= x2; x++) for (let z = z1; z <= z2; z++) for (let y = y1; y <= y2; y++) {
      const edgeX = x === x1 || x === x2;
      const edgeZ = z === z1 || z === z2;
      let type;
      if (y === y1) type = mat(t.floor);
      else if (y === y2) type = mat(t.ceiling);
      else if (edgeX || edgeZ) type = mat(t.wall);
      else type = "air";
      yield* place(dim, { x, y, z }, type);
    }
    yield;
  };

  const roomOrigin = (i, j) => ({ x: ox + i * PITCH, z: oz + j * PITCH });
  const kinds = roomKinds(r);
  const rooms = [];

  // залы
  for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) {
    const o = roomOrigin(i, j);
    yield* box(o.x, y0, o.z, o.x + ROOM - 1, y0 + HEIGHT, o.z + ROOM - 1);
    rooms.push({ i, j, kind: kinds[`${i},${j}`], cx: o.x + 4, cz: o.z + 4, done: false });
  }

  // коридоры (интерьер 3 в ширину, 3 в высоту)
  for (const [[i1, j1], [i2, j2]] of layout(r)) {
    const a = roomOrigin(Math.min(i1, i2), Math.min(j1, j2));
    if (i1 !== i2) {
      const x1 = a.x + ROOM - 1, x2 = a.x + PITCH, cz = a.z + 4;
      for (let x = x1; x <= x2; x++) for (let z = cz - 2; z <= cz + 2; z++) for (let y = y0; y <= y0 + 4; y++) {
        const inside = z > cz - 2 && z < cz + 2 && y > y0 && y < y0 + 4;
        const inWallPlane = x === x1 || x === x2;
        if (inside) yield* place(dim, { x, y, z }, "air");
        else if (!inWallPlane) yield* place(dim, { x, y, z }, y === y0 ? mat(t.floor) : mat(t.wall));
      }
    } else {
      const z1 = a.z + ROOM - 1, z2 = a.z + PITCH, cx = a.x + 4;
      for (let z = z1; z <= z2; z++) for (let x = cx - 2; x <= cx + 2; x++) for (let y = y0; y <= y0 + 4; y++) {
        const inside = x > cx - 2 && x < cx + 2 && y > y0 && y < y0 + 4;
        const inWallPlane = z === z1 || z === z2;
        if (inside) yield* place(dim, { x, y, z }, "air");
        else if (!inWallPlane) yield* place(dim, { x, y, z }, y === y0 ? mat(t.floor) : mat(t.wall));
      }
    }
    yield;
  }

  // убранство залов
  for (const room of rooms) {
    const { cx, cz } = room;
    // свет
    if (t.lightOnFloor) {
      for (const [dx, dz] of [[-3, -3], [3, 3], [-3, 3], [3, -3]]) yield* place(dim, { x: cx + dx, y: y0 + 1, z: cz + dz }, t.light);
    } else {
      yield* place(dim, { x: cx, y: y0 + HEIGHT, z: cz }, t.light);
      yield* place(dim, { x: cx - 3, y: y0 + HEIGHT, z: cz - 3 }, t.light);
      yield* place(dim, { x: cx + 3, y: y0 + HEIGHT, z: cz + 3 }, t.light);
    }
    // мелкий декор у стен
    for (let k = 0; k < 4; k++) {
      const dx = Math.floor(r() * 7) - 3, dz = Math.floor(r() * 7) - 3;
      if (Math.abs(dx) < 3 && Math.abs(dz) < 3) continue;
      const [d] = pick(t.decor, r);
      const y = d === "chain" || d === "cobweb" ? y0 + HEIGHT - 1 : y0 + 1;
      yield* place(dim, { x: cx + dx, y, z: cz + dz }, d);
    }
    if (room.kind === "loot") yield* placeChest(dim, { x: cx, y: y0 + 1, z: cz }, t.loot, EXTRA_LOOT, r);
    if (room.kind === "trap" && t.trap === "powder_snow") {
      for (let k = 0; k < 6; k++) {
        const x = cx + Math.floor(r() * 7) - 3, z = cz + Math.floor(r() * 7) - 3;
        yield* place(dim, { x, y: y0, z }, "powder_snow");
        yield* place(dim, { x, y: y0 - 1, z }, "powder_snow");
      }
    }
    if (room.kind === "boss") {
      // постамент
      for (let dx = -1; dx <= 1; dx++) for (let dz = -1; dz <= 1; dz++) yield* place(dim, { x: cx + dx, y: y0, z: cz + dz }, mat(t.wall));
      yield* place(dim, { x: cx, y: y0, z: cz }, "crying_obsidian");
    }
  }

  // лестница к поверхности от северной стены входа
  const ent = roomOrigin(1, 0);
  const ex = ent.x + 4;
  let z = ent.z; // плоскость северной стены
  let y = y0 + 1;
  let steps = 0;
  while (steps < 60) {
    // проход 3×3 над ступенью
    for (let dx = -2; dx <= 2; dx++) for (let dy = -1; dy <= 3; dy++) {
      const inside = Math.abs(dx) <= 1 && dy >= 0 && dy <= 2;
      const p = { x: ex + dx, y: y + dy, z };
      if (inside) yield* place(dim, p, "air");
      else {
        const b = getBlock(dim, p);
        if (b && (b.isAir || b.isLiquid || dy === -1)) yield* place(dim, p, dy === -1 ? mat(t.floor) : mat(t.wall));
      }
    }
    yield;
    let top;
    try {
      top = dim.getTopmostBlock({ x: ex, z });
    } catch {}
    if (top && y + 1 > top.location.y) break;
    z--;
    y++;
    steps++;
  }
  // арка на поверхности
  for (const dx of [-2, 2]) for (let dy = 0; dy <= 3; dy++) yield* place(dim, { x: ex + dx, y: y + dy, z }, t.surface);
  for (let dx = -2; dx <= 2; dx++) yield* place(dim, { x: ex + dx, y: y + 4, z }, t.surface);

  site.state = "built";
  site.y0 = y0;
  site.ox = ox;
  site.oz = oz;
  site.rooms = rooms;
  site.boss = 0; // 0 — не вызван, 1 — жив, 2 — побеждён
  site.entrance = { x: ex, y, z };
  saveSite(site);
  indexSite(site.key);
}

function* placeChest(dim, loc, table, extra, r) {
  yield* place(dim, loc, "chest");
  try {
    dim.runCommand(`loot insert ${loc.x} ${loc.y} ${loc.z} loot "${table}"`);
  } catch {}
  const inv = getBlock(dim, loc)?.getComponent("minecraft:inventory")?.container;
  if (!inv) return;
  const n = 2 + Math.floor(r() * 3);
  for (let k = 0; k < n; k++) {
    const [id, min, max] = pick(extra, r);
    try {
      inv.addItem(new ItemStack(id, min + Math.floor(r() * (max - min + 1))));
    } catch {}
  }
}

// ---------------------------------------------------------------- проверка и запуск постройки

function tryBuildNear(p) {
  if (p.dimension.id !== "minecraft:overworld") return;
  const loc = p.location;
  const cx0 = Math.floor(loc.x / CELL), cz0 = Math.floor(loc.z / CELL);
  for (let cx = cx0 - 1; cx <= cx0 + 1; cx++) for (let cz = cz0 - 1; cz <= cz0 + 1; cz++) {
    const site = siteFor(cx, cz);
    if (!site || building.has(site.key)) continue;
    if (Math.hypot(site.x - loc.x, site.z - loc.z) > BUILD_DISTANCE) continue;
    if (loadSite(site.key)) continue; // уже построен или пропущен
    const dim = p.dimension;
    // все углы должны быть загружены
    const half = Math.floor(SIZE / 2) + 1;
    const corners = [[-half, -half], [half, -half], [-half, half], [half, half], [0, -half - 30]];
    if (corners.some(([dx, dz]) => !getBlock(dim, { x: site.x + dx, y: 0, z: site.z + dz }))) continue;
    let top;
    try {
      top = dim.getTopmostBlock({ x: site.x, z: site.z });
    } catch {}
    if (!top) continue;
    if (top.isLiquid) {
      setJson(world, site.key, { key: site.key, state: "skipped" });
      continue;
    }
    building.add(site.key);
    setJson(world, site.key, { key: site.key, state: "building" });
    const job = buildDungeon(site, dim, top.location.y);
    system.runJob((function* () {
      try {
        yield* job;
      } catch (e) {
        console.warn("[adventure] dungeon build: " + e);
      }
      building.delete(site.key);
    })());
  }
}

// ---------------------------------------------------------------- события внутри данжа

function inSite(s, loc) {
  return loc.x >= s.ox - 1 && loc.x <= s.ox + SIZE && loc.z >= s.oz - 1 && loc.z <= s.oz + SIZE
    && loc.y >= s.y0 - 1 && loc.y <= s.y0 + HEIGHT + 1;
}

function inRoom(s, room, loc) {
  return Math.abs(loc.x - (room.cx + 0.5)) <= 4 && Math.abs(loc.z - (room.cz + 0.5)) <= 4
    && loc.y >= s.y0 && loc.y <= s.y0 + HEIGHT;
}

function spawnMob(dim, type, loc, opts = {}) {
  try {
    const e = dim.spawnEntity(type, loc);
    e.addTag("adv_dg");
    if (opts.name) e.nameTag = opts.name;
    if (opts.elite) {
      e.addEffect("strength", 20 * 600, { amplifier: 0, showParticles: false });
      e.addEffect("resistance", 20 * 600, { amplifier: 0, showParticles: false });
      e.addEffect("speed", 20 * 600, { amplifier: 0, showParticles: false });
    }
    particle(dim, "minecraft:large_explosion", loc);
    return e;
  } catch {
    return undefined;
  }
}

function roomSpawnPoints(s, room, n) {
  const pts = [];
  for (let k = 0; k < n; k++) {
    const a = (k / n) * Math.PI * 2;
    pts.push({ x: room.cx + 0.5 + Math.cos(a) * 3, y: s.y0 + 1, z: room.cz + 0.5 + Math.sin(a) * 3 });
  }
  return pts;
}

function triggerRoom(s, room, dim, players) {
  const t = THEMES[s.theme];
  const r = rng(Math.random());
  const n = Math.min(5, 1 + players);
  room.done = true;
  if (room.kind === "mobs") {
    for (const pt of roomSpawnPoints(s, room, n)) spawnMob(dim, pick(t.mobs, r)[0], pt);
  } else if (room.kind === "elite") {
    for (const pt of roomSpawnPoints(s, room, Math.max(2, n - 1))) spawnMob(dim, t.elite, pt, { elite: true, name: "§cСтраж" });
  } else if (room.kind === "trap") {
    room.trapUntil = system.currentTick + 20 * 25;
    for (const pt of roomSpawnPoints(s, room, Math.max(1, n - 2))) spawnMob(dim, pick(t.mobs, r)[0], pt);
  } else if (room.kind === "boss" && s.boss === 0) {
    s.boss = 1;
    const loc = { x: room.cx + 0.5, y: s.y0 + 1, z: room.cz + 0.5 };
    const b = spawnMob(dim, t.boss.type, loc, { name: t.boss.name });
    if (b) {
      b.addTag("adv_boss");
      b.addTag(`adv_site:${s.key}`);
      b.setDynamicProperty("adv:boss_max", 20 + 4 * (t.boss.hp + 1));
      b.addEffect("health_boost", 20 * 3600, { amplifier: t.boss.hp, showParticles: false });
      b.addEffect("instant_health", 1, { amplifier: 4 });
      b.addEffect("resistance", 20 * 3600, { amplifier: 1, showParticles: false });
      b.addEffect("strength", 20 * 3600, { amplifier: 1, showParticles: false });
      b.addEffect("fire_resistance", 20 * 3600, { amplifier: 0, showParticles: false });
      s.bossId = b.id;
    }
    sound(dim, "mob.wither.spawn", loc, 0.8);
    for (const pl of world.getAllPlayers()) {
      if (inSite(s, pl.location)) {
        pl.onScreenDisplay.setTitle(t.boss.name, { subtitle: "§7пробудился", fadeInDuration: 5, stayDuration: 50, fadeOutDuration: 10 });
      }
    }
  }
  saveSite(s);
}

function trapTick(s, room, dim, players) {
  const t = THEMES[s.theme];
  if (t.trap === "arrows") {
    for (const pl of players) {
      const side = Math.floor(Math.random() * 4);
      const off = [[-4, 0], [4, 0], [0, -4], [0, 4]][side];
      const from = { x: room.cx + 0.5 + off[0], y: s.y0 + 2.2, z: room.cz + 0.5 + off[1] };
      try {
        const arrow = dim.spawnEntity("minecraft:arrow", from);
        const dir = V.norm(V.sub(V.add(pl.location, { x: 0, y: 1, z: 0 }), from));
        arrow.getComponent("minecraft:projectile")?.shoot(V.mul(dir, 1.6));
        sound(dim, "random.bow", from, 1.2, 0.7);
      } catch {}
    }
  } else if (t.trap === "fire") {
    const x = room.cx + Math.floor(Math.random() * 7) - 3, z = room.cz + Math.floor(Math.random() * 7) - 3;
    const loc = { x: x + 0.5, y: s.y0 + 1, z: z + 0.5 };
    for (let k = 0; k < 6; k++) particle(dim, "minecraft:basic_flame_particle", { x: loc.x, y: loc.y + k * 0.4, z: loc.z });
    particle(dim, "minecraft:lava_particle", loc);
    sound(dim, "mob.blaze.shoot", loc, 0.8, 0.6);
    for (const pl of players) {
      if (Math.hypot(pl.location.x - loc.x, pl.location.z - loc.z) < 1.6) {
        try {
          pl.setOnFire(4, true);
          pl.applyDamage(3);
        } catch {}
      }
    }
  } else if (t.trap === "powder_snow") {
    for (const pl of players) {
      try {
        pl.addEffect("slowness", 40, { amplifier: 1 });
      } catch {}
      particle(dim, "minecraft:snowflake_particle", V.add(pl.location, { x: 0, y: 2.5, z: 0 }));
    }
  }
}

function onBossDefeated(s) {
  const t = THEMES[s.theme];
  const dim = world.getDimension("minecraft:overworld");
  const room = s.rooms.find((rm) => rm.kind === "boss");
  s.boss = 2;
  saveSite(s);
  if (!room) return;
  const r = rng(Math.random());
  system.runJob((function* () {
    yield* placeChest(dim, { x: room.cx - 1, y: s.y0 + 1, z: room.cz }, t.bossLoot, BOSS_EXTRA, r);
    yield* placeChest(dim, { x: room.cx + 1, y: s.y0 + 1, z: room.cz }, t.loot, EXTRA_LOOT, r);
  })());
  const loc = { x: room.cx + 0.5, y: s.y0 + 2, z: room.cz + 0.5 };
  for (let k = 0; k < 12; k++) {
    try {
      dim.spawnEntity("minecraft:xp_orb", loc);
    } catch {}
  }
  particle(dim, "minecraft:totem_particle", loc);
  sound(dim, "random.totem", loc);
  for (const pl of world.getAllPlayers()) {
    if (pl.dimension.id === dim.id && inSite(s, pl.location)) {
      pl.onScreenDisplay.setTitle("§aПобеда!", { subtitle: `${t.color}${t.name}§7 зачищена`, fadeInDuration: 5, stayDuration: 60, fadeOutDuration: 15 });
    }
  }
}

world.afterEvents.entityDie.subscribe((ev) => {
  const e = ev.deadEntity;
  let tags;
  try {
    tags = e.getTags();
  } catch {
    return;
  }
  if (!tags.includes("adv_boss")) return;
  const key = tags.find((x) => x.startsWith("adv_site:"))?.slice(9);
  const s = key && loadSite(key);
  if (s && s.boss === 1) onBossDefeated(s);
});

// ---------------------------------------------------------------- цикл

let loop = 0;

export function tickDungeons() {
  loop++;
  const overworld = world.getDimension("minecraft:overworld");
  const players = world.getAllPlayers().filter((p) => p.dimension.id === "minecraft:overworld");
  if (!players.length) return;

  if (loop % 4 === 0) for (const p of players) tryBuildNear(p);

  for (const key of rememberBuiltKeys()) {
    const s = loadSite(key);
    if (!s || s.state !== "built") continue;
    const inside = players.filter((p) => inSite(s, p.location));
    if (!inside.length) continue;
    const t = THEMES[s.theme];

    for (const p of inside) {
      if (addWaypoint(p, { kind: "dungeon", key: s.key, name: t.name, x: s.entrance.x, y: s.entrance.y, z: s.entrance.z, dim: "minecraft:overworld" })) {
        p.onScreenDisplay.setTitle(`${t.color}${t.name}`, { subtitle: "§7данж отмечен в навигаторе", fadeInDuration: 5, stayDuration: 40, fadeOutDuration: 10 });
      }
    }
    for (const room of s.rooms) {
      const here = inside.filter((p) => inRoom(s, room, p.location));
      if (!room.done && here.length && room.kind !== "entrance" && room.kind !== "loot") {
        triggerRoom(s, room, overworld, here.length);
      }
      if (room.kind === "trap" && (room.trapUntil ?? 0) > system.currentTick && here.length && loop % 2 === 0) {
        trapTick(s, room, overworld, here);
      }
    }

    // босс: полоска здоровья и приспешники
    if (s.boss === 1 && s.bossId) {
      const b = world.getEntity(s.bossId);
      if (!isValid(b)) continue;
      const hp = b.getComponent("minecraft:health");
      const max = Number(b.getDynamicProperty("adv:boss_max")) || hp.effectiveMax;
      const cur = Math.max(0, Math.round(hp.currentValue));
      const n = Math.round((cur / max) * 20);
      const bar = "§c" + "|".repeat(n) + "§8" + "|".repeat(20 - n);
      for (const p of inside) p.onScreenDisplay.setActionBar(`${t.boss.name} ${bar} §f${cur}/${max}`);
      if (loop % 20 === 0) {
        spawnMob(overworld, t.boss.minion, V.add(b.location, { x: 1, y: 0, z: 1 }));
        if (s.theme === "frost") for (const p of inside) p.addEffect("slowness", 60, { amplifier: 1 });
        if (s.theme === "forge") for (const p of inside) if (V.dist(p.location, b.location) < 5) p.setOnFire(3, true);
      }
    }
  }
}

/** Для админов: построить данж нужного вида рядом с игроком (/scriptevent adv:dungeon crypt). */
export function forceDungeon(p, theme) {
  if (!THEMES[theme]) theme = THEME_KEYS[Math.floor(Math.random() * THEME_KEYS.length)];
  const dir = p.getViewDirection();
  const x = Math.floor(p.location.x + dir.x * 25), z = Math.floor(p.location.z + dir.z * 25);
  const key = `adv:dg:force_${Date.now().toString(36)}`;
  const site = { key, x, z, theme, seed: Math.random() };
  let top;
  try {
    top = p.dimension.getTopmostBlock({ x, z });
  } catch {}
  if (!top) {
    p.sendMessage("§cМесто не загружено");
    return;
  }
  building.add(key);
  system.runJob((function* () {
    try {
      yield* buildDungeon(site, p.dimension, top.location.y);
      p.sendMessage(`§aДанж «${THEMES[theme].name}» построен. Вход: ${site.entrance.x} ${site.entrance.y} ${site.entrance.z}`);
    } catch (e) {
      console.warn("[adventure] force: " + e);
    }
    building.delete(key);
  })());
}
