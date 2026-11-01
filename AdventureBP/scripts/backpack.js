// Рюкзак: меню + хранилище без потерь.
//
// Вещи лежат в «отсеках» — бочках на 27 слотов, сохранённых как структуры мира
// (так сохраняется всё: зачарования, книги, шалкеры, карты). Меню рюкзака работает
// с отсеками незаметно: на один тик ставит бочку, перекладывает вещи и убирает её.
// «Открыть как сундук» ставит бочку перед игроком, как раньше.
import { world, system, StructureSaveMode, BlockPermutation } from "@minecraft/server";
import { ActionFormData } from "@minecraft/server-ui";
import { V, getBlock, getJson, setJson, sound, actionbar, isValid, mainhand, setMainhand, showForm } from "./util.js";
import { MENU_FORM_FLAG } from "./nav.js";
import { itemName } from "./names.js";

const SLOTS = 27;
const MAX_COMPARTMENTS = 4;
// стоимость следующего отсека (ключ — текущее число отсеков)
const UPGRADE_COST = {
  1: [["minecraft:leather", 8, "кожа"], ["minecraft:iron_ingot", 4, "железный слиток"]],
  2: [["minecraft:leather", 8, "кожа"], ["minecraft:gold_ingot", 4, "золотой слиток"]],
  3: [["minecraft:leather", 8, "кожа"], ["minecraft:diamond", 2, "алмаз"]],
};
const PAGE_SIZE = 4;
const PACK_DISTANCE = 7;
const PACK_TIMEOUT_TICKS = 20 * 60 * 5;
const OPEN_KEY = "adv:bp_open"; // в мире: { [ключ]: { id, k, dim, x, y, z, owner, tick } }
const UI = "textures/ui/adv/";

function structureId(id, k) {
  return k ? `adv:backpack_${id}_${k}` : `adv:backpack_${id}`;
}

function openKey(id, k) {
  return k ? `${id}#${k}` : id;
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

function inventory(p) {
  return p.getComponent("minecraft:inventory")?.container;
}

/** Найти рюкзак с этим id в инвентаре игрока. */
function findBackpack(p, id) {
  const inv = inventory(p);
  if (!inv) return undefined;
  for (let i = 0; i < inv.size; i++) {
    const it = inv.getItem(i);
    if (it?.typeId === "adv:backpack" && it.getDynamicProperty("adv:bp_id") === id) return { slot: i, item: it, inv };
  }
  return undefined;
}

function compartments(item) {
  return Math.max(1, Math.min(MAX_COMPARTMENTS, Number(item.getDynamicProperty("adv:bp_n")) || 1));
}

/** Найти свободное место для бочки перед игроком. */
function findSpot(p) {
  const dim = p.dimension;
  const dir = p.getViewDirection();
  const f = { x: dir.x, y: 0, z: dir.z };
  const len = Math.sqrt(f.x * f.x + f.z * f.z) || 1;
  const base = p.location;
  const busy = Object.values(getOpen());
  for (const dist of [1.6, 2.4, 1, 3.2]) {
    for (const dy of [0, 1, -1, 2]) {
      const loc = V.floor({ x: base.x + (f.x / len) * dist, y: base.y + dy, z: base.z + (f.z / len) * dist });
      if (busy.some((o) => o.x === loc.x && o.y === loc.y && o.z === loc.z)) continue;
      const b = getBlock(dim, loc);
      if (b && (b.isAir || /short_grass|tall_grass|fern|snow_layer/.test(b.typeId))) return loc;
    }
  }
  return undefined;
}

function placeCompartment(dim, loc, id, k) {
  const sm = world.structureManager;
  if (sm.get(structureId(id, k))) sm.place(structureId(id, k), dim, loc);
  else dim.getBlock(loc).setPermutation(BlockPermutation.resolve("minecraft:barrel", { facing_direction: 1 }));
  return getBlock(dim, loc)?.getComponent("minecraft:inventory")?.container;
}

/** Убрать бочку, не выронив вещи (их копия уже в структуре). */
function removeBarrel(dim, loc) {
  const block = getBlock(dim, loc);
  block?.getComponent("minecraft:inventory")?.container?.clearAll();
  block?.setType("minecraft:air");
}

/** Сохранить бочку как отсек и убрать её. */
function saveAndRemove(dim, loc, id, k) {
  const sm = world.structureManager;
  if (sm.get(structureId(id, k))) sm.delete(structureId(id, k));
  sm.createFromWorld(structureId(id, k), dim, loc, loc, {
    includeBlocks: true,
    includeEntities: false,
    saveMode: StructureSaveMode.World,
  });
  removeBarrel(dim, loc);
}

/**
 * Выполнить fn(container) над отсеком k. Если отсек открыт как сундук —
 * работаем прямо с ним, иначе на один тик ставим бочку и убираем.
 */
function withCompartment(p, id, k, fn, modify) {
  const o = getOpen()[openKey(id, k)];
  if (o) {
    const dim = world.getDimension(o.dim);
    const c = getBlock(dim, o)?.getComponent("minecraft:inventory")?.container;
    if (!c) throw new Error("отсек открыт далеко");
    return fn(c);
  }
  const loc = findSpot(p);
  if (!loc) throw new Error("нет места рядом");
  const dim = p.dimension;
  const c = placeCompartment(dim, loc, id, k);
  try {
    if (!c) throw new Error("не удалось открыть отсек");
    return fn(c);
  } finally {
    if (modify) saveAndRemove(dim, loc, id, k);
    else removeBarrel(dim, loc);
  }
}

// ---------------------------------------------------------------- использование

export function useBackpack(p) {
  const item = mainhand(p);
  if (!item || item.typeId !== "adv:backpack") return;
  let id = item.getDynamicProperty("adv:bp_id");
  if (typeof id !== "string") {
    id = newId();
    item.setDynamicProperty("adv:bp_id", id);
    try {
      item.setLore(["§7Нажми, чтобы открыть меню рюкзака"]);
    } catch {}
    setMainhand(p, item);
  }
  // если отсеки открыты как сундук — повторное нажатие их складывает
  const open = getOpen();
  const mine = Object.keys(open).filter((key) => (open[key].id ?? key) === id);
  if (mine.length) {
    for (const key of mine) packBackpack(key, p);
    return;
  }
  openMenu(p, id);
}

function openMenu(p, id) {
  const found = findBackpack(p, id);
  if (!found) return;
  const n = compartments(found.item);
  const form = new ActionFormData()
    .title(MENU_FORM_FLAG + "§lРюкзак")
    .body(`§7Отсеков: §f${n}§7 из ${MAX_COMPARTMENTS} · §f${n * SLOTS}§7 слотов`)
    .button("Вещи", UI + "list")
    .button("Сложить инвентарь\n§7всё, кроме хотбара", UI + "store")
    .button("Открыть как сундук", UI + "chest");
  const canUpgrade = n < MAX_COMPARTMENTS;
  if (canUpgrade) {
    const cost = UPGRADE_COST[n].map(([, c, name]) => `${c} ${name}`).join(", ");
    form.button(`Улучшить: +${SLOTS} слотов\n§7${cost}`, UI + "upgrade");
  }
  showForm(form, p, (res) => {
    switch (res.selection) {
      case 0:
        return openItems(p, id, 0);
      case 1:
        return storeInventory(p, id);
      case 2:
        return n === 1 ? openAsChest(p, id, 0) : chooseCompartment(p, id, n);
      case 3:
        if (canUpgrade) return upgrade(p, id);
    }
  });
}

// ---------------------------------------------------------------- список вещей

function collectItems(p, id, n) {
  const list = [];
  for (let k = 0; k < n; k++) {
    withCompartment(p, id, k, (c) => {
      for (let s = 0; s < c.size; s++) {
        const it = c.getItem(s);
        if (!it) continue;
        let ench = false;
        try {
          ench = (it.getComponent("minecraft:enchantable")?.getEnchantments().length ?? 0) > 0;
        } catch {}
        list.push({ k, slot: s, typeId: it.typeId, amount: it.amount, name: it.nameTag || itemName(it.typeId), ench });
      }
    }, false);
  }
  return list;
}

function openItems(p, id, page) {
  const found = findBackpack(p, id);
  if (!found) return;
  const n = compartments(found.item);
  let list;
  try {
    list = collectItems(p, id, n);
  } catch (e) {
    actionbar(p, "§cНе удалось открыть рюкзак: " + e.message);
    return;
  }
  const pages = Math.max(1, Math.ceil(list.length / PAGE_SIZE));
  page = Math.max(0, Math.min(page, pages - 1));
  const shown = list.slice(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE);
  const form = new ActionFormData()
    .title(MENU_FORM_FLAG + "§lВещи в рюкзаке")
    .body(list.length
      ? `§7Нажми на вещь, чтобы забрать её. Страница ${page + 1} из ${pages} · стаков: ${list.length}/${n * SLOTS}`
      : "§7Рюкзак пуст.");
  for (const e of shown) {
    form.button(`§f${e.name}${e.ench ? " §d(зачар.)" : ""} §7×${e.amount}\n§8отсек ${e.k + 1}`, UI + "item");
  }
  const hasNext = page < pages - 1;
  if (hasNext) form.button("Следующая страница", UI + "next");
  form.button(page > 0 ? "Предыдущая страница" : "Назад", UI + "back");
  showForm(form, p, (res) => {
    const sel = res.selection;
    if (sel < shown.length) return takeItem(p, id, shown[sel], page);
    if (hasNext && sel === shown.length) return openItems(p, id, page + 1);
    if (page > 0) return openItems(p, id, page - 1);
    openMenu(p, id);
  });
}

function takeItem(p, id, e, page) {
  const inv = inventory(p);
  if (!inv) return;
  let result;
  try {
    result = withCompartment(p, id, e.k, (c) => {
      const it = c.getItem(e.slot);
      if (!it || it.typeId !== e.typeId) return "changed";
      const before = it.amount;
      const left = c.transferItem(e.slot, inv);
      if (!left) return "ok";
      return left.amount < before ? "partial" : "full";
    }, true);
  } catch (err) {
    actionbar(p, "§c" + err.message);
    return;
  }
  if (result === "full") actionbar(p, "§cИнвентарь полон");
  else if (result === "partial") actionbar(p, "§eЗабрал часть — инвентарь полон");
  else if (result === "changed") actionbar(p, "§7Вещь уже переместили");
  else sound(p.dimension, "random.pop", p.location, 1.2, 0.6);
  openItems(p, id, page);
}

// ---------------------------------------------------------------- сложить инвентарь

function storeInventory(p, id) {
  const found = findBackpack(p, id);
  const inv = inventory(p);
  if (!found || !inv) return;
  const n = compartments(found.item);
  const slots = [];
  for (let s = 9; s < inv.size; s++) {
    const it = inv.getItem(s);
    if (it && it.typeId !== "adv:backpack") slots.push(s);
  }
  if (!slots.length) {
    actionbar(p, "§7Нечего складывать: вне хотбара пусто");
    return openMenu(p, id);
  }
  try {
    for (let k = 0; k < n; k++) {
      const left = slots.filter((s) => inv.getItem(s));
      if (!left.length) break;
      withCompartment(p, id, k, (c) => {
        for (const s of left) inv.transferItem(s, c);
      }, true);
    }
  } catch (err) {
    actionbar(p, "§c" + err.message);
    return;
  }
  const remaining = slots.filter((s) => inv.getItem(s)).length;
  const moved = slots.length - remaining;
  sound(p.dimension, "armor.equip_leather", p.location, 1);
  actionbar(p, remaining
    ? `§eСложено стаков: ${moved}. Не поместилось: ${remaining}`
    : `§aСложено стаков: ${moved}`);
  openMenu(p, id);
}

// ---------------------------------------------------------------- улучшение

function countItem(inv, typeId) {
  let n = 0;
  for (let s = 0; s < inv.size; s++) {
    const it = inv.getItem(s);
    if (it?.typeId === typeId) n += it.amount;
  }
  return n;
}

function removeItem(inv, typeId, amount) {
  for (let s = 0; s < inv.size && amount > 0; s++) {
    const it = inv.getItem(s);
    if (it?.typeId !== typeId) continue;
    const take = Math.min(amount, it.amount);
    amount -= take;
    if (take === it.amount) inv.setItem(s, undefined);
    else {
      it.amount -= take;
      inv.setItem(s, it);
    }
  }
}

function upgrade(p, id) {
  const found = findBackpack(p, id);
  if (!found) return;
  const n = compartments(found.item);
  const cost = UPGRADE_COST[n];
  if (!cost) return openMenu(p, id);
  const missing = cost.filter(([type, c]) => countItem(found.inv, type) < c);
  if (missing.length) {
    actionbar(p, "§cНе хватает: " + missing.map(([type, c, name]) => `${name} ${countItem(found.inv, type)}/${c}`).join(", "));
    return openMenu(p, id);
  }
  for (const [type, c] of cost) removeItem(found.inv, type, c);
  const again = findBackpack(p, id);
  if (!again) return;
  again.item.setDynamicProperty("adv:bp_n", n + 1);
  try {
    again.item.setLore([`§7Отсеков: ${n + 1} (${(n + 1) * SLOTS} слотов)`, "§7Нажми, чтобы открыть меню рюкзака"]);
  } catch {}
  again.inv.setItem(again.slot, again.item);
  sound(p.dimension, "random.levelup", p.location, 1.4);
  actionbar(p, `§aРюкзак улучшен: ${(n + 1) * SLOTS} слотов`);
  openMenu(p, id);
}

// ---------------------------------------------------------------- открыть как сундук

function chooseCompartment(p, id, n) {
  const form = new ActionFormData().title(MENU_FORM_FLAG + "§lКакой отсек открыть?").body("§7Каждый отсек — 27 слотов.");
  for (let k = 0; k < n; k++) form.button(`Отсек ${k + 1}`, UI + "chest");
  form.button("Назад", UI + "back");
  showForm(form, p, (res) => {
    if (res.selection < n) return openAsChest(p, id, res.selection);
    openMenu(p, id);
  });
}

function openAsChest(p, id, k) {
  const loc = findSpot(p);
  if (!loc) {
    actionbar(p, "§cНет места перед тобой, чтобы открыть рюкзак");
    return;
  }
  const dim = p.dimension;
  try {
    placeCompartment(dim, loc, id, k);
  } catch (e) {
    actionbar(p, "§cНе удалось открыть рюкзак");
    console.warn("[adventure] backpack place: " + e);
    return;
  }
  const open = getOpen();
  open[openKey(id, k)] = { id, k, dim: dim.id, x: loc.x, y: loc.y, z: loc.z, owner: p.id, tick: system.currentTick };
  setOpen(open);
  sound(dim, "armor.equip_leather", loc, 1);
  actionbar(p, "§6Отсек открыт §7— нажми на бочку. Нажми рюкзак ещё раз или отойди, чтобы сложить.");
}

/** Сложить открытый отсек: сохранить бочку с содержимым и убрать её. */
export function packBackpack(key, p) {
  const open = getOpen();
  const o = open[key];
  if (!o) return true;
  const id = o.id ?? key;
  const k = o.k ?? 0;
  let dim;
  try {
    dim = world.getDimension(o.dim);
  } catch {
    return false;
  }
  const loc = { x: o.x, y: o.y, z: o.z };
  const block = getBlock(dim, loc);
  if (!block) return false; // чанк не загружен — попробуем позже
  if (block.typeId === "minecraft:barrel") {
    try {
      saveAndRemove(dim, loc, id, k);
    } catch (e) {
      console.warn("[adventure] backpack pack: " + e);
      return false;
    }
    sound(dim, "armor.equip_leather", loc, 0.8);
    if (p) actionbar(p, "§6Рюкзак сложен");
  } else if (p) {
    actionbar(p, "§cБочку рюкзака сломали — вещи выпали на землю");
  }
  delete open[key];
  setOpen(open);
  return true;
}

// Бочку открытого отсека нельзя сломать.
world.beforeEvents.playerBreakBlock.subscribe((ev) => {
  const l = ev.block.location;
  const open = getOpen();
  for (const key in open) {
    const o = open[key];
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

/** Автоматически складываем отсеки, от которых отошли. */
export function tickBackpacks() {
  const open = getOpen();
  for (const key of Object.keys(open)) {
    const o = open[key];
    const owner = world.getEntity(o.owner);
    const far = !isValid(owner) || owner.dimension.id !== o.dim
      || V.dist(owner.location, { x: o.x + 0.5, y: o.y, z: o.z + 0.5 }) > PACK_DISTANCE;
    const old = system.currentTick - o.tick > PACK_TIMEOUT_TICKS || system.currentTick < o.tick;
    if (far || old) packBackpack(key, isValid(owner) ? owner : undefined);
  }
}
