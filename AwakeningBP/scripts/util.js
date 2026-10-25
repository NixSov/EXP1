import { world, system, EntityDamageCause } from "@minecraft/server";

// ---------------------------------------------------------------- векторы

export const V = {
  add: (a, b) => ({ x: a.x + b.x, y: a.y + b.y, z: a.z + b.z }),
  sub: (a, b) => ({ x: a.x - b.x, y: a.y - b.y, z: a.z - b.z }),
  mul: (a, k) => ({ x: a.x * k, y: a.y * k, z: a.z * k }),
  len: (a) => Math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z),
  dist: (a, b) => V.len(V.sub(a, b)),
  norm: (a) => {
    const l = V.len(a) || 1;
    return { x: a.x / l, y: a.y / l, z: a.z / l };
  },
  dot: (a, b) => a.x * b.x + a.y * b.y + a.z * b.z,
  flat: (a) => {
    const l = Math.sqrt(a.x * a.x + a.z * a.z) || 1;
    return { x: a.x / l, y: 0, z: a.z / l };
  },
  floor: (a) => ({ x: Math.floor(a.x), y: Math.floor(a.y), z: Math.floor(a.z) }),
  center: (a) => ({ x: Math.floor(a.x) + 0.5, y: Math.floor(a.y), z: Math.floor(a.z) + 0.5 }),
};

export function isValid(e) {
  if (!e) return false;
  try {
    return typeof e.isValid === "function" ? e.isValid() : !!e.isValid;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------- эффекты

// Частица вплотную к камере превращается в огромный квадрат на весь экран
// (на телефоне — чёрный). Поэтому рядом с головой игрока частицы не создаём.
const CAMERA_CLEARANCE = 2.2;
let headsTick = -1;
let heads = [];

function nearCamera(dim, loc) {
  if (headsTick !== system.currentTick) {
    headsTick = system.currentTick;
    heads = [];
    for (const p of world.getAllPlayers()) {
      try {
        heads.push({ dimId: p.dimension.id, loc: p.getHeadLocation() });
      } catch {}
    }
  }
  for (const h of heads) if (h.dimId === dim.id && V.dist(h.loc, loc) < CAMERA_CLEARANCE) return true;
  return false;
}

export function particle(dim, id, loc) {
  if (nearCamera(dim, loc)) return;
  try {
    dim.spawnParticle(id, loc);
  } catch {}
}

export function particleLine(dim, id, from, to, step = 0.6) {
  const d = V.sub(to, from);
  const n = Math.max(1, Math.floor(V.len(d) / step));
  for (let i = 0; i <= n; i++) particle(dim, id, V.add(from, V.mul(d, i / n)));
}

export function particleRing(dim, id, center, radius, count = 24, y = 0.2) {
  for (let i = 0; i < count; i++) {
    const a = (i / count) * Math.PI * 2;
    particle(dim, id, { x: center.x + Math.cos(a) * radius, y: center.y + y, z: center.z + Math.sin(a) * radius });
  }
}

export function particleSphere(dim, id, center, radius, count = 30) {
  for (let i = 0; i < count; i++) {
    const u = Math.random() * 2 - 1;
    const a = Math.random() * Math.PI * 2;
    const r = Math.sqrt(1 - u * u);
    particle(dim, id, { x: center.x + r * Math.cos(a) * radius, y: center.y + u * radius, z: center.z + r * Math.sin(a) * radius });
  }
}

export function sound(dim, id, loc, pitch = 1, volume = 1) {
  try {
    dim.playSound(id, loc, { pitch, volume });
  } catch {}
}

export function effect(entity, id, ticks, amplifier = 0, showParticles = true) {
  try {
    entity.addEffect(id, ticks, { amplifier, showParticles });
  } catch {}
}

export function ignite(entity, seconds) {
  try {
    entity.setOnFire(seconds, true);
  } catch {}
}

export function knock(entity, dir, horizontal, vertical) {
  try {
    const f = V.flat(dir);
    entity.applyKnockback({ x: f.x * horizontal, z: f.z * horizontal }, vertical);
  } catch {}
}

// Сообщения способностей не должны сразу затираться строкой перезарядки.
export const actionbarHold = new Map(); // playerId -> tick

export function actionbar(player, text, hold = true) {
  try {
    player.onScreenDisplay.setActionBar(text);
    if (hold) actionbarHold.set(player.id, system.currentTick + 30);
  } catch {}
}

// ---------------------------------------------------------------- цели и урон

const IGNORE_TYPES = new Set([
  "minecraft:item", "minecraft:xp_orb", "minecraft:arrow", "minecraft:snowball", "minecraft:egg",
  "minecraft:fireball", "minecraft:small_fireball", "minecraft:lightning_bolt", "minecraft:armor_stand",
  "minecraft:painting", "minecraft:leash_knot", "minecraft:fishing_hook", "minecraft:area_effect_cloud",
  "minecraft:ender_pearl", "minecraft:thrown_trident", "minecraft:wind_charge_projectile",
]);

/** Можно ли бить эту сущность способностью игрока. */
export function isTarget(e, caster) {
  if (!isValid(e) || e.id === caster.id) return false;
  if (IGNORE_TYPES.has(e.typeId)) return false;
  try {
    if (!e.getComponent("minecraft:health")) return false;
    if (e.typeId === "minecraft:player") {
      const gm = e.getGameMode?.();
      if (gm === "Creative" || gm === "Spectator" || gm === "creative" || gm === "spectator") return false;
    }
    const tame = e.getComponent("minecraft:tameable");
    if (tame && tame.isTamed && tame.tamedToPlayerId === caster.id) return false;
  } catch {
    return false;
  }
  return true;
}

export function targetsInRadius(caster, center, radius, dim = caster.dimension) {
  let list = [];
  try {
    list = dim.getEntities({ location: center, maxDistance: radius });
  } catch {}
  return list.filter((e) => isTarget(e, caster));
}

/** Сущности в конусе взгляда. */
export function targetsInCone(caster, range, minDot = 0.8) {
  const eye = caster.getHeadLocation();
  const dir = caster.getViewDirection();
  return targetsInRadius(caster, eye, range).filter((e) => {
    const to = V.sub(V.add(e.location, { x: 0, y: 0.9, z: 0 }), eye);
    return V.dot(V.norm(to), dir) >= minDot;
  });
}

/** Первая цель по взгляду. */
export function lookTarget(caster, range) {
  try {
    const hits = caster.getEntitiesFromViewDirection({ maxDistance: range });
    for (const h of hits) if (isTarget(h.entity, caster)) return h.entity;
  } catch {}
  // запасной вариант: ближайшая цель в узком конусе
  const list = targetsInCone(caster, range, 0.96);
  list.sort((a, b) => V.dist(a.location, caster.location) - V.dist(b.location, caster.location));
  return list[0];
}

/** Точка, куда смотрит игрок (блок или максимальная дистанция). */
export function lookPoint(caster, range) {
  const eye = caster.getHeadLocation();
  const dir = caster.getViewDirection();
  try {
    const hit = caster.getBlockFromViewDirection({ maxDistance: range });
    if (hit) {
      const p = V.add(hit.block.location, hit.faceLocation);
      return V.sub(p, V.mul(dir, 0.3));
    }
  } catch {}
  return V.add(eye, V.mul(dir, range));
}

// Кто и когда в последний раз ранил сущность способностью — для подсчёта убийств.
export const lastAbilityHit = new Map();

export function damage(caster, target, amount, opts = {}) {
  if (!isTarget(target, caster)) return false;
  let hostile = false;
  try {
    hostile = target.matches({ families: ["monster"] });
  } catch {}
  lastAbilityHit.set(target.id, { playerId: caster.id, tick: system.currentTick, ult: !!opts.ult, hostile });
  try {
    return target.applyDamage(amount, {
      cause: opts.cause ?? EntityDamageCause.entityAttack,
      damagingEntity: caster,
    });
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------- блоки

const SOFT = /(short_grass|tall_grass|seagrass|fern|flower|tulip|poppy|dandelion|orchid|allium|bluet|daisy|cornflower|lily|torch|vine|sapling|button|lever|carpet|rail|snow_layer|deadbush|dead_bush|sugar_cane|kelp|sign|banner|pressure_plate|frame|web|bush|roots|sprouts)/;

export function getBlock(dim, loc) {
  try {
    return dim.getBlock(V.floor(loc));
  } catch {
    return undefined;
  }
}

export function isPassable(block) {
  if (!block) return false;
  try {
    return block.isAir || block.isLiquid || SOFT.test(block.typeId);
  } catch {
    return false;
  }
}

/** Свободно ли место для игрока (2 блока высотой). */
export function isStandable(dim, loc) {
  return isPassable(getBlock(dim, loc)) && isPassable(getBlock(dim, V.add(loc, { x: 0, y: 1, z: 0 })));
}

/** Последняя безопасная точка по направлению взгляда. */
export function safePointAlongView(player, range) {
  const dim = player.dimension;
  const dir = player.getViewDirection();
  const start = player.location;
  let best;
  for (let d = 1; d <= range; d += 0.5) {
    const p = V.add(start, V.mul(dir, d));
    const eyeBlock = getBlock(dim, V.add(p, { x: 0, y: 1.6, z: 0 }));
    if (!isPassable(eyeBlock) && !isPassable(getBlock(dim, p))) break;
    if (isStandable(dim, p)) best = p;
  }
  return best;
}

/** Найти безопасное место рядом с точкой (вверх до 3 блоков). */
export function findStandable(dim, loc) {
  for (let dy = 0; dy <= 3; dy++) {
    const p = V.add(loc, { x: 0, y: dy, z: 0 });
    if (isStandable(dim, p)) return p;
  }
  return undefined;
}

// ---------------------------------------------------------------- снаряды

/**
 * Летящий «снаряд» из частиц: двигается каждый тик, взрывается о блок или сущность.
 * onHit(point, entity | undefined) вызывается один раз.
 */
export function projectile(caster, opts) {
  const dim = caster.dimension;
  const dir = caster.getViewDirection();
  let pos = V.add(caster.getHeadLocation(), V.mul(dir, 0.8));
  const speed = opts.speed ?? 1.5;
  const range = opts.range ?? 40;
  let travelled = 0;
  const id = system.runInterval(() => {
    if (!isValid(caster)) return system.clearRun(id);
    const sub = Math.ceil(speed / 0.5);
    for (let i = 0; i < sub; i++) {
      pos = V.add(pos, V.mul(dir, speed / sub));
      travelled += speed / sub;
      const block = getBlock(dim, pos);
      const hitEntity = targetsInRadius(caster, pos, opts.hitRadius ?? 1.3, dim)[0];
      if (hitEntity || (block && !isPassable(block)) || travelled >= range) {
        system.clearRun(id);
        opts.onHit(pos, hitEntity);
        return;
      }
      if (i % 2 === 0 && travelled > 2.5) for (const p of opts.particles) particle(dim, p, pos);
    }
  }, 1);
}

/** Повторять fn(tickIndex) каждые every тиков count раз. */
export function repeat(count, every, fn, done) {
  let n = 0;
  const id = system.runInterval(() => {
    try {
      fn(n);
    } catch (e) {
      console.warn("[awakening] " + e);
    }
    n++;
    if (n >= count) {
      system.clearRun(id);
      if (done) done();
    }
  }, every);
  return id;
}
