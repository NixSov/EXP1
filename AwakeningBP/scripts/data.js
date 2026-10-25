import { ItemStack, ItemLockMode, EquipmentSlot } from "@minecraft/server";
import { POWERS } from "./defs.js";
import { sound, particleSphere, isValid } from "./util.js";

export const MAX_LEVEL = 30;
export const MAX_RANK = 5;
export const ORB_ID = "aw:awakening_orb";

// ---------------------------------------------------------------- хранение

function getNum(p, key, def = 0) {
  const v = p.getDynamicProperty(key);
  return typeof v === "number" ? v : def;
}

function getJson(p, key, def) {
  const v = p.getDynamicProperty(key);
  if (typeof v !== "string") return def;
  try {
    return JSON.parse(v);
  } catch {
    return def;
  }
}

export function getPower(p) {
  const id = p.getDynamicProperty("aw:power");
  return typeof id === "string" ? POWERS[id] : undefined;
}

export function getLevel(p) {
  return getNum(p, "aw:level", 1);
}

export function getXp(p) {
  return getNum(p, "aw:xp", 0);
}

export function getSkillPoints(p) {
  return getNum(p, "aw:sp", 0);
}

export function xpForNext(level) {
  return 40 + level * 30;
}

export function getRanks(p) {
  return getJson(p, "aw:ranks", [1, 1, 1, 1, 1]);
}

export function getRank(p, index) {
  return getRanks(p)[index] ?? 1;
}

export function getStats(p) {
  return getJson(p, "aw:stats", { uses: 0, kills: 0, hostile: 0, ult: 0 });
}

function setStats(p, s) {
  p.setDynamicProperty("aw:stats", JSON.stringify(s));
}

export function getQuestIndex(p) {
  return getNum(p, "aw:quest", 0);
}

export function getBrinkCount(p) {
  return getNum(p, "aw:brink", 0);
}

export function setBrinkCount(p, n) {
  p.setDynamicProperty("aw:brink", n);
}

export function isUnlocked(p, ability) {
  return getLevel(p) >= ability.unlock;
}

// ---------------------------------------------------------------- множители

/** Множитель урона: +4% за уровень, +15% за ранг способности. */
export function dmgMul(p, index) {
  return (1 + 0.04 * (getLevel(p) - 1)) * (1 + 0.15 * (getRank(p, index) - 1));
}

/** Перезарядка в тиках: −8% за ранг. */
export function cooldownTicks(p, ability) {
  const k = 1 - 0.08 * (getRank(p, ability.index) - 1);
  return Math.round(ability.cd * 20 * k);
}

// ---------------------------------------------------------------- предметы

export function makeLocked(id, lore) {
  const item = new ItemStack(id, 1);
  try {
    item.lockMode = ItemLockMode.inventory;
    item.keepOnDeath = true;
  } catch {}
  if (lore) {
    try {
      item.setLore(lore);
    } catch {}
  }
  return item;
}

function inventory(p) {
  return p.getComponent("minecraft:inventory")?.container;
}

export function hasItem(p, id) {
  const inv = inventory(p);
  if (!inv) return false;
  for (let i = 0; i < inv.size; i++) if (inv.getItem(i)?.typeId === id) return true;
  try {
    const eq = p.getComponent("minecraft:equippable");
    if (eq?.getEquipment(EquipmentSlot.Offhand)?.typeId === id) return true;
  } catch {}
  return false;
}

export function giveItem(p, item) {
  const inv = inventory(p);
  const rest = inv?.addItem(item);
  if (rest) p.dimension.spawnItem(rest, p.location);
}

export function ensureOrb(p) {
  if (!hasItem(p, ORB_ID)) giveItem(p, makeLocked(ORB_ID, ["§7Нажми, чтобы открыть меню силы"]));
}

/** Выдать недостающие предметы открытых способностей. Возвращает число выданных. */
export function giveAbilityItems(p) {
  const power = getPower(p);
  if (!power) return 0;
  let n = 0;
  for (const ab of power.abilities) {
    if (!isUnlocked(p, ab) || hasItem(p, ab.id)) continue;
    giveItem(p, makeLocked(ab.id, [`§7${ab.desc}`, ab.ult ? "§6Ульта" : "§8Присядь + нажми — ульта"]));
    n++;
  }
  return n;
}

/** Забрать все предметы способностей (при смене силы). */
export function removeAbilityItems(p) {
  const inv = inventory(p);
  if (!inv) return;
  for (let i = 0; i < inv.size; i++) {
    const it = inv.getItem(i);
    if (it && /^aw:(pyro|cryo|storm|tele|grav)_\d$/.test(it.typeId)) inv.setItem(i, undefined);
  }
}

// ---------------------------------------------------------------- прогресс

export function setPower(p, powerId, resetProgress = true) {
  removeAbilityItems(p);
  p.setDynamicProperty("aw:power", powerId);
  if (resetProgress) {
    p.setDynamicProperty("aw:level", 1);
    p.setDynamicProperty("aw:xp", 0);
    p.setDynamicProperty("aw:sp", 0);
    p.setDynamicProperty("aw:ranks", JSON.stringify([1, 1, 1, 1, 1]));
  }
  giveAbilityItems(p);
}

export function clearPower(p) {
  removeAbilityItems(p);
  for (const k of ["aw:power", "aw:level", "aw:xp", "aw:sp", "aw:ranks", "aw:stats", "aw:quest", "aw:brink"]) {
    p.setDynamicProperty(k, undefined);
  }
}

export function addSkillPoints(p, n) {
  p.setDynamicProperty("aw:sp", getSkillPoints(p) + n);
}

export function upgradeAbility(p, index) {
  const ranks = getRanks(p);
  const cost = ranks[index];
  if (ranks[index] >= MAX_RANK || getSkillPoints(p) < cost) return false;
  ranks[index]++;
  p.setDynamicProperty("aw:ranks", JSON.stringify(ranks));
  p.setDynamicProperty("aw:sp", getSkillPoints(p) - cost);
  return true;
}

export function setLevel(p, level) {
  const old = getLevel(p);
  level = Math.max(1, Math.min(MAX_LEVEL, level));
  p.setDynamicProperty("aw:level", level);
  if (level > old) addSkillPoints(p, level - old);
  onLevelChanged(p, old, level);
}

export function addXp(p, amount) {
  if (!getPower(p) || !isValid(p)) return;
  let level = getLevel(p);
  if (level >= MAX_LEVEL) return;
  let xp = getXp(p) + amount;
  const old = level;
  while (level < MAX_LEVEL && xp >= xpForNext(level)) {
    xp -= xpForNext(level);
    level++;
  }
  p.setDynamicProperty("aw:xp", xp);
  if (level !== old) {
    p.setDynamicProperty("aw:level", level);
    addSkillPoints(p, level - old);
    onLevelChanged(p, old, level);
  }
}

function onLevelChanged(p, old, level) {
  if (level <= old) return;
  const power = getPower(p);
  p.onScreenDisplay.setTitle(`§6Уровень ${level}`, {
    subtitle: "§e+ очко навыка",
    fadeInDuration: 5,
    stayDuration: 40,
    fadeOutDuration: 10,
  });
  sound(p.dimension, "random.levelup", p.location);
  particleSphere(p.dimension, "minecraft:totem_particle", p.location, 1.5, 20);
  if (!power) return;
  for (const ab of power.abilities) {
    if (ab.unlock > old && ab.unlock <= level) {
      p.sendMessage(`§aОткрыта способность: ${power.color}${ab.name}§a!`);
    }
  }
  giveAbilityItems(p);
  checkQuest(p);
}

// ---------------------------------------------------------------- квесты

export const QUESTS = [
  { name: "Первые шаги", desc: "Используй способности 15 раз", stat: "uses", goal: 15, xp: 60, sp: 1 },
  { name: "Охотник", desc: "Убей способностями 10 существ", stat: "kills", goal: 10, xp: 120, sp: 1 },
  { name: "Растущая сила", desc: "Достигни 5 уровня", stat: "level", goal: 5, xp: 0, sp: 2 },
  { name: "Истребитель", desc: "Убей способностями 30 монстров", stat: "hostile", goal: 30, xp: 250, sp: 2 },
  { name: "Мощь ульты", desc: "Убей ультой 5 существ", stat: "ult", goal: 5, xp: 300, sp: 2 },
  { name: "Мастер силы", desc: "Используй способности 300 раз", stat: "uses", goal: 300, xp: 400, sp: 2 },
  { name: "Легенда", desc: "Достигни 15 уровня", stat: "level", goal: 15, xp: 0, sp: 3, diamonds: 8 },
  { name: "Бессмертный", desc: "Убей способностями 150 монстров", stat: "hostile", goal: 150, xp: 800, sp: 3 },
];

export function questProgress(p, q) {
  if (q.stat === "level") return getLevel(p);
  return getStats(p)[q.stat] ?? 0;
}

export function currentQuest(p) {
  return QUESTS[getQuestIndex(p)];
}

export function bumpStat(p, stat, n = 1) {
  const s = getStats(p);
  s[stat] = (s[stat] ?? 0) + n;
  setStats(p, s);
  checkQuest(p);
}

const notified = new Set();

export function checkQuest(p) {
  const q = currentQuest(p);
  if (!q) return;
  const key = p.id + ":" + getQuestIndex(p);
  if (questProgress(p, q) >= q.goal && !notified.has(key)) {
    notified.add(key);
    p.sendMessage(`§a>> Задание «${q.name}» выполнено! §7Забери награду в Сфере Пробуждения.`);
    sound(p.dimension, "random.orb", p.location, 1.2);
  }
}

export function claimQuest(p) {
  const q = currentQuest(p);
  if (!q || questProgress(p, q) < q.goal) return false;
  p.setDynamicProperty("aw:quest", getQuestIndex(p) + 1);
  if (q.sp) addSkillPoints(p, q.sp);
  if (q.diamonds) giveItem(p, new ItemStack("minecraft:diamond", q.diamonds));
  if (q.xp) addXp(p, q.xp);
  sound(p.dimension, "random.levelup", p.location, 1.3);
  return true;
}
