import { system, EntityDamageCause } from "@minecraft/server";
import {
  V, isValid, particle, particleLine, particleRing, particleSphere, sound, effect, ignite, knock, actionbar,
  targetsInRadius, targetsInCone, lookTarget, lookPoint, damage, getBlock, isPassable,
  safePointAlongView, findStandable, projectile, repeat,
} from "./util.js";

const UP = { x: 0, y: 1, z: 0 };

// Состояния, живущие между тиками.
export const cryoArmorUntil = new Map(); // playerId -> tick
const teleMarks = new Map(); // playerId -> { loc, dimId, tick }

function dash(p, horizontal, vertical) {
  knock(p, p.getViewDirection(), horizontal, vertical);
}

function aoe(p, center, radius, amount, extra, opts) {
  const hit = targetsInRadius(p, center, radius);
  for (const e of hit) {
    damage(p, e, amount, opts);
    if (extra) extra(e);
  }
  return hit.length;
}

// ============================================================ ПИРОКИНЕТИК

function fireball(p, m) {
  sound(p.dimension, "mob.blaze.shoot", p.location);
  projectile(p, {
    speed: 1.6,
    range: 40,
    particles: ["minecraft:basic_flame_particle", "minecraft:lava_particle"],
    onHit: (pos) => {
      particle(p.dimension, "minecraft:huge_explosion_emitter", pos);
      sound(p.dimension, "random.explode", pos, 1.2, 0.8);
      aoe(p, pos, 2.8, 7 * m, (e) => ignite(e, 5));
    },
  });
  return true;
}

function fireWave(p, m) {
  const c = p.location;
  sound(p.dimension, "mob.ghast.fireball", c);
  for (let r = 1; r <= 5; r++) {
    system.runTimeout(() => particleRing(p.dimension, "minecraft:basic_flame_particle", c, r, 10 + r * 6, 0.3), r);
  }
  aoe(p, c, 5.5, 6 * m, (e) => {
    ignite(e, 6);
    knock(e, V.sub(e.location, c), 1.4, 0.4);
  });
  return true;
}

function fireDash(p, m) {
  dash(p, 3.2, 0.25);
  sound(p.dimension, "fire.ignite", p.location);
  effect(p, "fire_resistance", 60, 0, false);
  const hit = new Set();
  repeat(10, 1, () => {
    if (!isValid(p)) return;
    particleSphere(p.dimension, "minecraft:basic_flame_particle", p.location, 0.7, 6);
    for (const e of targetsInRadius(p, p.location, 2.2)) {
      if (hit.has(e.id)) continue;
      hit.add(e.id);
      damage(p, e, 4 * m);
      ignite(e, 4);
    }
  });
  return true;
}

function flamethrower(p, m) {
  sound(p.dimension, "mob.blaze.breathe", p.location);
  repeat(20, 2, (i) => {
    if (!isValid(p)) return;
    const eye = p.getHeadLocation();
    const dir = p.getViewDirection();
    for (let d = 1; d <= 7; d += 1) {
      const spread = d * 0.25;
      particle(p.dimension, "minecraft:basic_flame_particle", {
        x: eye.x + dir.x * d + (Math.random() - 0.5) * spread,
        y: eye.y + dir.y * d + (Math.random() - 0.5) * spread - 0.2,
        z: eye.z + dir.z * d + (Math.random() - 0.5) * spread,
      });
    }
    if (i % 2 === 0) {
      for (const e of targetsInCone(p, 7.5, 0.82)) {
        damage(p, e, 2 * m, { cause: EntityDamageCause.fire });
        ignite(e, 5);
      }
    }
    if (i % 5 === 0) sound(p.dimension, "mob.blaze.shoot", p.location, 0.7, 0.5);
  });
  return true;
}

function meteor(p, m) {
  const target = lookPoint(p, 45);
  const dim = p.dimension;
  const sky = V.add(target, { x: 6, y: 25, z: 6 });
  particleRing(dim, "minecraft:lava_particle", target, 3, 20);
  sound(dim, "mob.wither.shoot", p.location, 0.6);
  repeat(20, 1, (i) => {
    const pos = V.add(sky, V.mul(V.sub(target, sky), i / 20));
    particleSphere(dim, "minecraft:basic_flame_particle", pos, 1.2, 10);
    particle(dim, "minecraft:large_explosion", pos);
    if (i % 4 === 0) particleRing(dim, "minecraft:lava_particle", target, 3.5 - i / 8, 16);
  }, () => {
    if (!isValid(p)) return;
    particle(dim, "minecraft:huge_explosion_emitter", target);
    for (let i = 0; i < 6; i++) {
      particle(dim, "minecraft:huge_explosion_emitter", V.add(target, { x: (Math.random() - 0.5) * 6, y: 0.5, z: (Math.random() - 0.5) * 6 }));
    }
    sound(dim, "random.explode", target, 0.6, 2);
    aoe(p, target, 6.5, 18 * m, (e) => {
      ignite(e, 8);
      knock(e, V.sub(e.location, target), 2, 0.6);
    }, { ult: true });
    try {
      dim.createExplosion(target, 2.5, { breaksBlocks: false, causesFire: true, source: p });
    } catch {}
  });
  return true;
}

// ============================================================ КРИОКИНЕТИК

function freeze(e, ticks, strength = 4) {
  effect(e, "slowness", ticks, strength);
  effect(e, "mining_fatigue", ticks, 2);
  effect(e, "weakness", ticks, 1);
}

function iceShard(p, m) {
  sound(p.dimension, "random.bow", p.location, 1.6);
  projectile(p, {
    speed: 2.2,
    range: 40,
    hitRadius: 1.1,
    particles: ["minecraft:snowflake_particle", "minecraft:endrod"],
    onHit: (pos, e) => {
      sound(p.dimension, "random.glass", pos, 1.3);
      particleSphere(p.dimension, "minecraft:snowflake_particle", pos, 0.8, 12);
      if (e) {
        damage(p, e, 6 * m);
        freeze(e, 80, 3);
      }
    },
  });
  return true;
}

function iceWall(p) {
  const dim = p.dimension;
  const f = V.flat(p.getViewDirection());
  const side = { x: -f.z, y: 0, z: f.x };
  const base = V.add(p.location, V.mul(f, 3));
  const placed = [];
  for (let s = -2; s <= 2; s++) {
    for (let h = 0; h < 3; h++) {
      const loc = V.floor(V.add(V.add(base, V.mul(side, s)), { x: 0, y: h, z: 0 }));
      const b = getBlock(dim, loc);
      if (b && (b.isAir || b.typeId === "minecraft:short_grass" || b.typeId === "minecraft:snow_layer")) {
        try {
          b.setType("minecraft:packed_ice");
          placed.push(loc);
          particle(dim, "minecraft:snowflake_particle", V.add(loc, { x: 0.5, y: 0.5, z: 0.5 }));
        } catch {}
      }
    }
  }
  if (!placed.length) {
    actionbar(p, "§cНет места для стены");
    return false;
  }
  sound(dim, "random.glass", base, 0.8);
  system.runTimeout(() => {
    for (const loc of placed) {
      const b = getBlock(dim, loc);
      if (b?.typeId === "minecraft:packed_ice") {
        try {
          b.setType("minecraft:air");
          particle(dim, "minecraft:snowflake_particle", V.add(loc, { x: 0.5, y: 0.5, z: 0.5 }));
        } catch {}
      }
    }
  }, 200);
  return true;
}

function frostBreath(p, m) {
  sound(p.dimension, "mob.player.hurt_freeze", p.location, 0.8);
  const eye = p.getHeadLocation();
  const dir = p.getViewDirection();
  for (let d = 1; d <= 8; d += 0.5) {
    for (let k = 0; k < 3; k++) {
      const spread = d * 0.3;
      particle(p.dimension, "minecraft:snowflake_particle", {
        x: eye.x + dir.x * d + (Math.random() - 0.5) * spread,
        y: eye.y + dir.y * d + (Math.random() - 0.5) * spread,
        z: eye.z + dir.z * d + (Math.random() - 0.5) * spread,
      });
    }
  }
  for (const e of targetsInCone(p, 8.5, 0.78)) {
    damage(p, e, 5 * m);
    freeze(e, 100, 6);
    particleSphere(p.dimension, "minecraft:snowflake_particle", V.add(e.location, UP), 0.8, 10);
  }
  return true;
}

function iceArmor(p, m) {
  const ticks = 240;
  effect(p, "resistance", ticks, 1);
  effect(p, "absorption", ticks, Math.min(4, Math.round(m)));
  cryoArmorUntil.set(p.id, system.currentTick + ticks);
  sound(p.dimension, "random.glass", p.location, 0.6);
  repeat(ticks / 10, 10, () => {
    if (isValid(p)) particleRing(p.dimension, "minecraft:snowflake_particle", p.location, 0.9, 10, 1);
  });
  return true;
}

function absoluteZero(p, m) {
  const dim = p.dimension;
  const c = p.location;
  sound(dim, "mob.elderguardian.curse", c, 1.4);
  sound(dim, "random.glass", c, 0.5, 2);
  for (let r = 1; r <= 10; r++) {
    system.runTimeout(() => {
      particleRing(dim, "minecraft:snowflake_particle", c, r, r * 8, 0.3);
      particleRing(dim, "minecraft:endrod", c, r, r * 3, 1.2);
    }, r);
  }
  aoe(p, c, 10, 14 * m, (e) => {
    freeze(e, 140, 10);
  }, { ult: true });
  // заморозить воду вокруг
  const base = V.floor(c);
  for (let dx = -8; dx <= 8; dx++) {
    for (let dz = -8; dz <= 8; dz++) {
      if (dx * dx + dz * dz > 64) continue;
      for (let dy = -2; dy <= 1; dy++) {
        const b = getBlock(dim, { x: base.x + dx, y: base.y + dy, z: base.z + dz });
        if (b?.typeId === "minecraft:water" && getBlock(dim, { x: base.x + dx, y: base.y + dy + 1, z: base.z + dz })?.isAir) {
          try {
            b.setType("minecraft:frosted_ice");
          } catch {}
        }
      }
    }
  }
  return true;
}

// ============================================================ ПОВЕЛИТЕЛЬ БУРЬ

function strike(p, loc, amount, radius, ult) {
  try {
    p.dimension.spawnEntity("minecraft:lightning_bolt", loc);
  } catch {}
  particleSphere(p.dimension, "minecraft:electric_spark_particle", V.add(loc, UP), 1.2, 16);
  aoe(p, loc, radius, amount, null, { ult, cause: EntityDamageCause.lightning });
}

function lightningStrike(p, m) {
  const t = lookTarget(p, 40);
  const loc = t ? t.location : lookPoint(p, 40);
  effect(p, "fire_resistance", 100, 0, false);
  strike(p, loc, 8 * m, 2.5, false);
  return true;
}

function chainLightning(p, m) {
  let target = lookTarget(p, 22);
  if (!target) {
    target = targetsInCone(p, 14, 0.6)[0];
  }
  if (!target) {
    actionbar(p, "§cНет цели");
    return false;
  }
  const hit = new Set();
  let from = V.add(p.getHeadLocation(), V.mul(p.getViewDirection(), 0.5));
  let amount = 7 * m;
  let jumps = 0;
  const step = () => {
    if (!target || !isValid(target) || jumps > 4) return;
    const to = V.add(target.location, { x: 0, y: 1, z: 0 });
    particleLine(p.dimension, "minecraft:electric_spark_particle", from, to, 0.4);
    particleLine(p.dimension, "minecraft:endrod", from, to, 1.2);
    sound(p.dimension, "random.orb", to, 0.5 + jumps * 0.2);
    damage(p, target, amount, { cause: EntityDamageCause.lightning });
    effect(target, "slowness", 30, 1);
    hit.add(target.id);
    from = to;
    amount *= 0.8;
    jumps++;
    const next = targetsInRadius(p, target.location, 7).filter((e) => !hit.has(e.id));
    next.sort((a, b) => V.dist(a.location, to) - V.dist(b.location, to));
    target = next[0];
    if (target) system.runTimeout(step, 3);
  };
  step();
  sound(p.dimension, "ambient.weather.lightning.impact", p.location, 1.5, 0.6);
  return true;
}

function stormDash(p, m) {
  dash(p, 3.4, 0.3);
  sound(p.dimension, "ambient.weather.thunder", p.location, 1.8, 0.5);
  repeat(8, 1, () => {
    if (isValid(p)) particleSphere(p.dimension, "minecraft:electric_spark_particle", p.location, 0.6, 5);
  }, () => {
    if (!isValid(p)) return;
    particleRing(p.dimension, "minecraft:electric_spark_particle", p.location, 3, 24, 0.3);
    sound(p.dimension, "random.explode", p.location, 1.8, 0.4);
    aoe(p, p.location, 3.5, 6 * m, (e) => effect(e, "slowness", 40, 2), { cause: EntityDamageCause.lightning });
  });
  return true;
}

function stormAura(p, m) {
  effect(p, "speed", 200, 1);
  sound(p.dimension, "beacon.activate", p.location, 1.5);
  repeat(40, 5, (i) => {
    if (!isValid(p)) return;
    particleRing(p.dimension, "minecraft:electric_spark_particle", p.location, 3.5, 14, 1);
    if (i % 4 === 0) {
      for (const e of targetsInRadius(p, p.location, 4)) {
        damage(p, e, 3.5 * m, { cause: EntityDamageCause.lightning });
        particleLine(p.dimension, "minecraft:electric_spark_particle", V.add(p.location, UP), V.add(e.location, UP), 0.5);
      }
    }
  });
  return true;
}

function tempest(p, m) {
  const dim = p.dimension;
  const c = p.location;
  sound(dim, "ambient.weather.thunder", c, 0.7, 2);
  effect(p, "fire_resistance", 200, 0, false);
  effect(p, "resistance", 120, 1, false);
  repeat(14, 6, () => {
    if (!isValid(p)) return;
    const near = targetsInRadius(p, p.location, 16);
    let loc;
    if (near.length && Math.random() < 0.8) {
      loc = near[Math.floor(Math.random() * near.length)].location;
    } else {
      const a = Math.random() * Math.PI * 2;
      const r = 4 + Math.random() * 10;
      loc = { x: p.location.x + Math.cos(a) * r, y: p.location.y, z: p.location.z + Math.sin(a) * r };
    }
    strike(p, loc, 10 * m, 3, true);
  });
  return true;
}

// ============================================================ ТЕЛЕПОРТЕР

function tpFx(dim, loc) {
  particleSphere(dim, "minecraft:portal_reverse_particle", V.add(loc, UP), 0.8, 20);
  sound(dim, "mob.endermen.portal", loc);
}

function tp(p, loc, facing) {
  try {
    p.teleport(loc, facing ? { facingLocation: facing } : { keepVelocity: false });
    return true;
  } catch {
    return false;
  }
}

function blink(p) {
  const dest = safePointAlongView(p, 16);
  if (!dest || V.dist(dest, p.location) < 1.5) {
    actionbar(p, "§cНекуда телепортироваться");
    return false;
  }
  tpFx(p.dimension, p.location);
  const ok = tp(p, dest);
  if (ok) tpFx(p.dimension, dest);
  return ok;
}

function mark(p) {
  const m = teleMarks.get(p.id);
  if (!m || system.currentTick - m.tick > 1200) {
    teleMarks.set(p.id, { loc: p.location, dimId: p.dimension.id, tick: system.currentTick });
    particleRing(p.dimension, "minecraft:portal_reverse_particle", p.location, 1, 20, 0.1);
    sound(p.dimension, "beacon.power", p.location, 1.6);
    actionbar(p, "§dМетка поставлена. §7Нажми ещё раз в течение 60 с, чтобы вернуться.");
    return "nocd";
  }
  if (m.dimId !== p.dimension.id) {
    actionbar(p, "§cМетка в другом измерении");
    teleMarks.delete(p.id);
    return false;
  }
  tpFx(p.dimension, p.location);
  tp(p, m.loc);
  tpFx(p.dimension, m.loc);
  teleMarks.delete(p.id);
  return true;
}

function backstab(p, m) {
  const t = lookTarget(p, 24);
  if (!t) {
    actionbar(p, "§cНет цели");
    return false;
  }
  let behind;
  try {
    const tdir = V.flat(t.getViewDirection());
    behind = findStandable(p.dimension, V.sub(t.location, V.mul(tdir, 1.6)));
  } catch {}
  if (!behind) {
    const back = V.flat(V.sub(t.location, p.location));
    behind = findStandable(p.dimension, V.add(t.location, V.mul(back, 1.6)));
  }
  if (!behind) behind = t.location;
  tpFx(p.dimension, p.location);
  tp(p, behind, V.add(t.location, UP));
  tpFx(p.dimension, behind);
  particle(p.dimension, "minecraft:critical_hit_emitter", V.add(t.location, UP));
  sound(p.dimension, "random.anvil_land", t.location, 1.8, 0.5);
  damage(p, t, 9 * m);
  effect(t, "slowness", 30, 1);
  return true;
}

function banish(p, m) {
  const t = lookTarget(p, 24);
  if (!t) {
    actionbar(p, "§cНет цели");
    return false;
  }
  const up = V.add(t.location, { x: 0, y: 12, z: 0 });
  let free = true;
  for (let y = 1; y <= 13 && free; y++) free = isPassable(getBlock(t.dimension, V.add(t.location, { x: 0, y, z: 0 })));
  tpFx(t.dimension, t.location);
  damage(p, t, 3 * m);
  try {
    if (free) t.teleport(up);
    else effect(t, "levitation", 40, 6);
  } catch {}
  tpFx(t.dimension, free ? up : t.location);
  return true;
}

function flurry(p, m) {
  const start = p.location;
  const startDim = p.dimension;
  const list = targetsInRadius(p, start, 16)
    .sort((a, b) => V.dist(a.location, start) - V.dist(b.location, start))
    .slice(0, 8);
  if (!list.length) {
    actionbar(p, "§cРядом нет врагов");
    return false;
  }
  effect(p, "resistance", 20 * 6, 3, false);
  sound(startDim, "mob.enderdragon.growl", start, 1.6, 0.6);
  let i = 0;
  const id = system.runInterval(() => {
    if (!isValid(p)) return system.clearRun(id);
    const t = list[i];
    if (t && isValid(t)) {
      const offset = V.mul(V.flat({ x: Math.random() - 0.5, y: 0, z: Math.random() - 0.5 }), 1.5);
      const dest = findStandable(p.dimension, V.add(t.location, offset)) ?? t.location;
      tpFx(p.dimension, p.location);
      tp(p, dest, V.add(t.location, UP));
      particle(p.dimension, "minecraft:critical_hit_emitter", V.add(t.location, UP));
      sound(p.dimension, "random.anvil_land", t.location, 2, 0.4);
      damage(p, t, 10 * m, { ult: true });
    }
    i++;
    if (i >= list.length) {
      system.clearRun(id);
      system.runTimeout(() => {
        if (!isValid(p) || p.dimension.id !== startDim.id) return;
        tpFx(p.dimension, p.location);
        tp(p, start);
        tpFx(p.dimension, start);
      }, 8);
    }
  }, 6);
  return true;
}

// ============================================================ ГРАВИТОН

function pull(p, m) {
  const c = p.location;
  sound(p.dimension, "mob.warden.sonic_charge", c, 1.4, 0.7);
  for (let r = 8; r >= 1; r -= 1.5) {
    system.runTimeout(() => particleRing(p.dimension, "minecraft:portal_reverse_particle", c, r, 20, 0.8), Math.round(8 - r));
  }
  aoe(p, c, 10, 2 * m, (e) => {
    const to = V.sub(c, e.location);
    knock(e, to, Math.min(3, V.len(to) * 0.35), 0.35);
  });
  return true;
}

function repulse(p, m) {
  const c = p.location;
  particle(p.dimension, "minecraft:sonic_explosion", V.add(c, UP));
  particleRing(p.dimension, "minecraft:knockback_roar_particle", c, 2, 12, 0.5);
  sound(p.dimension, "mob.warden.sonic_boom", c, 1.3, 0.7);
  aoe(p, c, 6.5, 5 * m, (e) => knock(e, V.sub(e.location, c), 3.2, 0.7));
  return true;
}

function weightless(p, m) {
  const t = lookTarget(p, 24);
  const center = t ? t.location : lookPoint(p, 24);
  particleRing(p.dimension, "minecraft:portal_reverse_particle", center, 3, 24, 0.2);
  sound(p.dimension, "mob.shulker.shoot", center, 0.8);
  const n = aoe(p, center, 3.5, 3 * m, (e) => {
    effect(e, "levitation", 50, 3);
    effect(e, "slowness", 60, 2);
  });
  if (!n) {
    actionbar(p, "§cНет цели");
    return false;
  }
  return true;
}

function antigravity(p) {
  knock(p, p.getViewDirection(), 0.3, 1.6);
  effect(p, "slow_falling", 300, 0);
  effect(p, "jump_boost", 300, 3);
  particleRing(p.dimension, "minecraft:portal_reverse_particle", p.location, 1.5, 20, 0.1);
  sound(p.dimension, "mob.enderdragon.flap", p.location, 1.2);
  return true;
}

function singularity(p, m) {
  const dim = p.dimension;
  const c = V.add(lookPoint(p, 28), { x: 0, y: 1.5, z: 0 });
  sound(dim, "mob.warden.sonic_charge", c, 0.5, 2);
  repeat(50, 2, (i) => {
    if (!isValid(p)) return;
    particleSphere(dim, "minecraft:portal_reverse_particle", c, 3 + (i % 4), 12);
    particleSphere(dim, "minecraft:dragon_breath_trail", c, 0.6, 6);
    for (const e of targetsInRadius(p, c, 11, dim)) {
      const to = V.sub(c, e.location);
      knock(e, to, Math.min(1.4, V.len(to) * 0.18), to.y > 0 ? 0.25 : 0.05);
      if (i % 10 === 0) damage(p, e, 3 * m, { ult: true });
    }
    if (i % 10 === 0) sound(dim, "mob.warden.heartbeat", c, 0.5, 1.5);
  }, () => {
    particle(dim, "minecraft:huge_explosion_emitter", c);
    particle(dim, "minecraft:sonic_explosion", c);
    sound(dim, "random.explode", c, 0.5, 2);
    aoe(p, c, 6, 14 * m, (e) => knock(e, V.sub(e.location, c), 2.5, 0.8), { ult: true });
  });
  return true;
}

// ============================================================ реестр

export const ABILITIES = {
  "aw:pyro_1": fireball,
  "aw:pyro_2": fireWave,
  "aw:pyro_3": fireDash,
  "aw:pyro_4": flamethrower,
  "aw:pyro_5": meteor,
  "aw:cryo_1": iceShard,
  "aw:cryo_2": iceWall,
  "aw:cryo_3": frostBreath,
  "aw:cryo_4": iceArmor,
  "aw:cryo_5": absoluteZero,
  "aw:storm_1": lightningStrike,
  "aw:storm_2": chainLightning,
  "aw:storm_3": stormDash,
  "aw:storm_4": stormAura,
  "aw:storm_5": tempest,
  "aw:tele_1": blink,
  "aw:tele_2": mark,
  "aw:tele_3": backstab,
  "aw:tele_4": banish,
  "aw:tele_5": flurry,
  "aw:grav_1": pull,
  "aw:grav_2": repulse,
  "aw:grav_3": weightless,
  "aw:grav_4": antigravity,
  "aw:grav_5": singularity,
};
