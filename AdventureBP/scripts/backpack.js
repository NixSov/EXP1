// Рюкзак: при использовании перед игроком появляется бочка с вещами рюкзака.
// Повторное использование (или если отойти) — бочка «складывается»: вместе с
// содержимым сохраняется как структура мира и исчезает. Вещи хранятся без потерь.
import { world, system, StructureSaveMode, ItemStack, BlockPermutation } from "@minecraft/server";
import { V, getBlock, getJson, setJson, sound, actionbar, isValid, mainhand, setMainhand } from "./util.js";

const PACK_DISTANCE = 7;
const PACK_TIMEOUT_TICKS = 20 * 60 * 5;
const OPEN_KEY = "adv:bp_open"; // в мире: { [bpId]: { dim, x, y, z, owner, tick } }

function structureId(bpId) {
  return `adv:backpack_${bpId}`;
}

function getOpen() {
  return getJson(world, OPEN_KEY, {});
}

function setOpen(map) {
  setJson(world, OPEN_KEY, map);
}

function newId() {
  return Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
}

/** Найти место для бочки перед игроком. */
function findSpot(p) {
  const dim = p.dimension;
  const dir = p.getViewDirection();
  const f = { x: dir.x, y: 0, z: dir.z };
  const len = Math.sqrt(f.x * f.x + f.z * f.z) || 1;
  const base = p.location;
  for (const dist of [1.6, 2.4, 1]) {
    for (const dy of [0, 1, -1]) {
      const loc = V.floor({ x: base.x + (f.x / len) * dist, y: base.y + dy, z: base.z + (f.z / len) * dist });
      const b = getBlock(dim, loc);
      if (b && (b.isAir || /short_grass|tall_grass|fern|snow_layer/.test(b.typeId))) return loc;
    }
  }
  return undefined;
}

export function useBackpack(p) {
  let item = mainhand(p);
  if (!item || item.typeId !== "adv:backpack") return;
  let id = item.getDynamicProperty("adv:bp_id");
  if (typeof id !== "string") {
    id = newId();
    item.setDynamicProperty("adv:bp_id", id);
    try {
      item.setLore(["§7Нажми, чтобы открыть", "§7Нажми ещё раз, чтобы сложить"]);
    } catch {}
    setMainhand(p, item);
  }

  const open = getOpen();
  if (open[id]) {
    packBackpack(id, p);
    return;
  }

  const loc = findSpot(p);
  if (!loc) {
    actionbar(p, "§cНет места перед тобой, чтобы открыть рюкзак");
    return;
  }
  const dim = p.dimension;
  const sm = world.structureManager;
  try {
    if (sm.get(structureId(id))) {
      sm.place(structureId(id), dim, loc);
    } else {
      dim.getBlock(loc).setPermutation(BlockPermutation.resolve("minecraft:barrel", { facing_direction: 1 }));
    }
  } catch (e) {
    actionbar(p, "§cНе удалось открыть рюкзак");
    console.warn("[adventure] backpack place: " + e);
    return;
  }
  open[id] = { dim: dim.id, x: loc.x, y: loc.y, z: loc.z, owner: p.id, tick: system.currentTick };
  setOpen(open);
  sound(dim, "armor.equip_leather", loc, 1);
  actionbar(p, "§6Рюкзак открыт §7— нажми на бочку. Нажми рюкзак ещё раз, чтобы сложить.");
}

/** Сложить рюкзак: сохранить бочку вместе с содержимым и убрать её из мира. */
export function packBackpack(id, p) {
  const open = getOpen();
  const o = open[id];
  if (!o) return true;
  let dim;
  try {
    dim = world.getDimension(o.dim);
  } catch {
    return false;
  }
  const loc = { x: o.x, y: o.y, z: o.z };
  const block = getBlock(dim, loc);
  if (!block) return false; // чанк не загружен — попробуем позже
  const sm = world.structureManager;
  if (block.typeId === "minecraft:barrel") {
    try {
      if (sm.get(structureId(id))) sm.delete(structureId(id));
      sm.createFromWorld(structureId(id), dim, loc, loc, {
        includeBlocks: true,
        includeEntities: false,
        saveMode: StructureSaveMode.World,
      });
      // сначала опустошаем бочку: иначе при удалении вещи выпадают на землю (дублирование)
      block.getComponent("minecraft:inventory")?.container?.clearAll();
      block.setType("minecraft:air");
    } catch (e) {
      console.warn("[adventure] backpack pack: " + e);
      return false;
    }
    sound(dim, "armor.equip_leather", loc, 0.8);
    if (p) actionbar(p, "§6Рюкзак сложен");
  } else if (p) {
    actionbar(p, "§cБочку рюкзака сломали — вещи выпали на землю");
  }
  delete open[id];
  setOpen(open);
  return true;
}

// Бочку открытого рюкзака нельзя сломать.
world.beforeEvents.playerBreakBlock.subscribe((ev) => {
  const l = ev.block.location;
  const open = getOpen();
  for (const id in open) {
    const o = open[id];
    if (o.x === l.x && o.y === l.y && o.z === l.z && o.dim === ev.block.dimension.id) {
      ev.cancel = true;
      system.run(() => actionbar(ev.player, "§7Это открытый рюкзак — сложи его, нажав рюкзак ещё раз"));
      return;
    }
  }
});

// Взрывы не трогают бочки рюкзаков.
world.beforeEvents.explosion.subscribe((ev) => {
  const open = getOpen();
  const keys = Object.values(open).filter((o) => o.dim === ev.dimension.id);
  if (!keys.length) return;
  const blocks = ev.getImpactedBlocks().filter((b) => {
    const l = b.location;
    return !keys.some((o) => o.x === l.x && o.y === l.y && o.z === l.z);
  });
  ev.setImpactedBlocks(blocks);
});

/** Автоматически складываем рюкзаки, от которых отошли. */
export function tickBackpacks() {
  const open = getOpen();
  const ids = Object.keys(open);
  if (!ids.length) return;
  for (const id of ids) {
    const o = open[id];
    const owner = world.getEntity(o.owner);
    const far = !isValid(owner) || owner.dimension.id !== o.dim
      || V.dist(owner.location, { x: o.x + 0.5, y: o.y, z: o.z + 0.5 }) > PACK_DISTANCE;
    const old = system.currentTick - o.tick > PACK_TIMEOUT_TICKS || system.currentTick < o.tick;
    if (far || old) packBackpack(id, isValid(owner) ? owner : undefined);
  }
}

export function makeBackpack() {
  return new ItemStack("adv:backpack", 1);
}
