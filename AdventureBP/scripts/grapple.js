// Крюк-кошка: цепляется за блок и подтягивает игрока или подтягивает моба к игроку.
// Без прочности. Уровень крюка влияет на дальность, скорость полёта и скорость подтягивания.
import { world, system } from "@minecraft/server";
import { GRAPPLE_TIERS } from "./glyphs.js";
import { V, isValid, particle, sound, actionbar } from "./util.js";

const active = new Map(); // playerId -> { stop() }
const fallProtect = new Map(); // playerId -> tick, до которого нет урона от падения

export function tierOf(typeId) {
  return GRAPPLE_TIERS.find((t) => t.id === typeId);
}

function drawRope(dim, from, to) {
  const d = V.sub(to, from);
  const len = V.len(d);
  const n = Math.min(40, Math.floor(len / 0.8));
  for (let i = 1; i <= n; i++) particle(dim, "minecraft:basic_crit_particle", V.add(from, V.mul(d, i / n)));
}

function handPoint(p) {
  // точка чуть впереди и ниже глаз — верёвка не лезет в камеру
  const eye = p.getHeadLocation();
  return V.add(V.add(eye, V.mul(p.getViewDirection(), 0.6)), { x: 0, y: -0.4, z: 0 });
}

function stopGrapple(p) {
  const a = active.get(p.id);
  if (a) a.stop();
}

export function useGrapple(p, tier) {
  if (active.has(p.id)) {
    stopGrapple(p);
    return;
  }
  const dim = p.dimension;
  let target;
  let anchor;
  let dist = Infinity;
  try {
    const hit = p.getBlockFromViewDirection({ maxDistance: tier.range });
    if (hit) {
      anchor = V.add(hit.block.location, hit.faceLocation);
      dist = V.dist(anchor, p.getHeadLocation());
    }
  } catch {}
  try {
    for (const h of p.getEntitiesFromViewDirection({ maxDistance: Math.min(tier.range, dist) })) {
      const e = h.entity;
      if (!isValid(e) || e.id === p.id || !e.getComponent("minecraft:health")) continue;
      target = e;
      dist = h.distance;
      break;
    }
  } catch {}
  if (!anchor && !target) {
    actionbar(p, `§7Крюк не достаёт (дальность ${tier.range} бл.)`);
    sound(dim, "random.bow", p.location, 0.6, 0.6);
    return;
  }

  sound(dim, "random.bow", p.location, 1.6);
  let state = "fly";
  let flown = 0;
  let pullTicks = 0;
  const maxPull = Math.ceil((dist / tier.speed) * 1.6) + 30;

  const id = system.runInterval(() => {
    if (!isValid(p) || p.dimension.id !== dim.id) return finish(false);
    const aim = target ? (isValid(target) ? V.add(target.location, { x: 0, y: 0.8, z: 0 }) : null) : anchor;
    if (!aim) return finish(false);
    const from = handPoint(p);

    if (state === "fly") {
      flown += tier.fly;
      const progress = Math.min(1, flown / Math.max(dist, 0.1));
      drawRope(dim, from, V.add(from, V.mul(V.sub(aim, from), progress)));
      if (progress >= 1) {
        state = "pull";
        sound(dim, target ? "random.bowhit" : "dig.stone", aim, 1.2);
      }
      return;
    }

    pullTicks++;
    if (p.isSneaking || pullTicks > maxPull) return finish(true);
    drawRope(dim, from, aim);

    if (target) {
      // тянем моба к игроку
      const to = V.sub(p.location, target.location);
      const d = V.len(to);
      if (d < 2.5) return finish(true);
      const n = V.norm(to);
      const s = Math.min(tier.speed, d * 0.4);
      try {
        target.applyKnockback({ x: n.x * s, z: n.z * s }, Math.max(0.15, n.y * s + 0.1));
      } catch {}
      return;
    }

    // тянем игрока к точке зацепа
    const to = V.sub(anchor, V.add(p.location, { x: 0, y: 0.9, z: 0 }));
    const d = V.len(to);
    if (d < 1.3) {
      // в конце — небольшой подскок, чтобы забраться на уступ
      try {
        p.applyKnockback({ x: 0, z: 0 }, 0.42);
      } catch {}
      return finish(true);
    }
    const n = V.norm(to);
    const s = Math.min(tier.speed, d * 0.5 + 0.2);
    try {
      p.applyKnockback({ x: n.x * s, z: n.z * s }, n.y * s + 0.08);
    } catch {}
  }, 1);

  function finish(ok) {
    system.clearRun(id);
    active.delete(p.id);
    if (!isValid(p)) return;
    fallProtect.set(p.id, system.currentTick + 10);
    if (ok) sound(p.dimension, "random.pop", p.location, 0.8, 0.5);
  }

  active.set(p.id, { stop: () => finish(false) });
}

/**
 * Защита от урона при падении после крюка: пока игрок не приземлился,
 * короткое медленное падение сбрасывает высоту падения.
 */
export function tickFallProtect() {
  for (const [pid, until] of fallProtect) {
    const p = active.has(pid) ? null : findPlayer(pid);
    if (!p) {
      if (!active.has(pid)) fallProtect.delete(pid);
      continue;
    }
    if (system.currentTick > until + 200 || (system.currentTick > until && p.isOnGround)) {
      fallProtect.delete(pid);
      continue;
    }
    if (p.isFalling && !p.isOnGround) {
      try {
        p.addEffect("slow_falling", 6, { amplifier: 0, showParticles: false });
      } catch {}
    }
  }
}

function findPlayer(id) {
  const e = world.getEntity(id);
  return isValid(e) ? e : undefined;
}
