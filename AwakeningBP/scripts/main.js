import { world, system, EntityDamageCause, EquipmentSlot } from "@minecraft/server";
import { POWERS } from "./defs.js";
import { ABILITIES, cryoArmorUntil } from "./abilities.js";
import {
  V, isValid, actionbar, actionbarHold, effect, damage, sound, particleSphere, particleRing, knock,
  targetsInRadius, getBlock, lastAbilityHit,
} from "./util.js";
import {
  ORB_ID, getPower, setPower, clearPower, isUnlocked, cooldownTicks, dmgMul, addXp, bumpStat,
  ensureOrb, giveAbilityItems, getBrinkCount, setBrinkCount, migrateItems,
} from "./data.js";
import { openMainMenu, openOblivion, openAdmin } from "./ui.js";

const SHARD_ID = "aw:oblivion_shard";
const ABILITY_RE = /^aw:(pyro|cryo|storm|tele|grav)_(\d)$/;

// ---------------------------------------------------------------- перезарядки

const cooldowns = new Map(); // "playerId|abilityId" -> тик готовности

function cdLeft(player, abilityId) {
  return Math.max(0, (cooldowns.get(player.id + "|" + abilityId) ?? 0) - system.currentTick);
}

function startCooldown(player, ability, ticks) {
  cooldowns.set(player.id + "|" + ability.id, system.currentTick + ticks);
  try {
    player.startItemCooldown(ability.cooldownCategory, ticks);
  } catch {}
}

// ---------------------------------------------------------------- применение предметов

const lastUseTick = new Map();

function onUseItem(player, item) {
  if (!item || !isValid(player)) return;
  const id = item.typeId;
  if (id !== ORB_ID && id !== SHARD_ID && !ABILITY_RE.test(id)) return;

  // itemUse и взаимодействие с блоком могут прийти вместе — обрабатываем один раз
  const last = lastUseTick.get(player.id) ?? -10;
  if (system.currentTick - last < 3) return;
  lastUseTick.set(player.id, system.currentTick);

  if (id === ORB_ID) {
    if (player.isSneaking && player.hasTag("aw_admin")) return openAdmin(player, awaken);
    return openMainMenu(player);
  }
  if (id === SHARD_ID) return useOblivion(player);
  castFromItem(player, id);
}

function castFromItem(player, itemId) {
  const power = getPower(player);
  const [, powerId, num] = itemId.match(ABILITY_RE);
  if (!power || power.id !== powerId) {
    actionbar(player, "§cЭто не твоя сила");
    return;
  }
  let ability = power.abilities[Number(num) - 1];

  // присед + использование = ульта
  const ult = power.abilities.find((a) => a.ult);
  if (player.isSneaking && ult && !ability.ult && isUnlocked(player, ult)) ability = ult;

  if (!isUnlocked(player, ability)) {
    actionbar(player, `§cОткроется на ${ability.unlock} уровне`);
    return;
  }
  const left = cdLeft(player, ability.id);
  if (left > 0) {
    actionbar(player, `§c${ability.name}: перезарядка ${(left / 20).toFixed(1)} с`);
    return;
  }
  const fn = ABILITIES[ability.id];
  let result = false;
  try {
    result = fn(player, dmgMul(player, ability.index));
  } catch (e) {
    console.warn(`[awakening] ${ability.id}: ${e}`);
  }
  if (!result) {
    startCooldown(player, ability, 10);
    return;
  }
  startCooldown(player, ability, result === "nocd" ? 20 : cooldownTicks(player, ability));
  if (ability.ult) {
    actionbar(player, `${power.color}§l${ability.name.toUpperCase()}`);
  }
  bumpStat(player, "uses");
}

function useOblivion(player) {
  openOblivion(player, () => {
    const power = getPower(player);
    if (!power) return;
    // забрать один осколок
    try {
      const eq = player.getComponent("minecraft:equippable");
      const it = eq.getEquipment(EquipmentSlot.Mainhand);
      if (it?.typeId === SHARD_ID) {
        if (it.amount > 1) {
          it.amount--;
          eq.setEquipment(EquipmentSlot.Mainhand, it);
        } else {
          eq.setEquipment(EquipmentSlot.Mainhand, undefined);
        }
      }
    } catch {}
    clearPower(player);
    player.setDynamicProperty("aw:prev", power.id);
    sound(player.dimension, "mob.elderguardian.curse", player.location);
    particleSphere(player.dimension, "minecraft:portal_reverse_particle", player.location, 1.5, 30);
    player.sendMessage(`§5Ты забыл силу ${power.color}${power.name}§5. Новая сила ждёт тебя на грани смерти...`);
  });
}

world.afterEvents.itemUse.subscribe((ev) => onUseItem(ev.source, ev.itemStack));

world.afterEvents.playerInteractWithBlock.subscribe((ev) => {
  if (ev.itemStack) onUseItem(ev.player, ev.itemStack);
});

// ---------------------------------------------------------------- пробуждение

function awaken(player, powerId) {
  if (!powerId) {
    const prev = player.getDynamicProperty("aw:prev");
    let ids = Object.keys(POWERS).filter((id) => id !== prev);
    if (!ids.length) ids = Object.keys(POWERS);
    powerId = ids[Math.floor(Math.random() * ids.length)];
  }
  const power = POWERS[powerId];
  setPower(player, powerId, true);
  setBrinkCount(player, 0);
  ensureOrb(player);

  const dim = player.dimension;
  const loc = player.location;
  effect(player, "regeneration", 100, 2);
  effect(player, "resistance", 80, 3);
  effect(player, "instant_health", 1, 1);
  for (const e of targetsInRadius(player, loc, 6)) knock(e, V.sub(e.location, loc), 2.5, 0.6);
  sound(dim, "random.totem", loc);
  sound(dim, "mob.wither.spawn", loc, 1.4, 0.6);
  particleSphere(dim, "minecraft:totem_particle", V.add(loc, { x: 0, y: 1, z: 0 }), 1.5, 40);
  for (let r = 1; r <= 6; r++) {
    system.runTimeout(() => particleRing(dim, "minecraft:endrod", loc, r, r * 8, 0.5), r * 2);
  }
  player.onScreenDisplay.setTitle("§6§lПРОБУЖДЕНИЕ", {
    subtitle: `${power.color}${power.name}`,
    fadeInDuration: 5,
    stayDuration: 70,
    fadeOutDuration: 20,
  });
  player.sendMessage(`§6Твоя сила пробудилась! §fТы — ${power.color}§l${power.name}§r§f.`);
  player.sendMessage("§7Предметы способностей добавлены в инвентарь. Положи их в хотбар и нажми «Использовать». Меню — Сфера Пробуждения.");
}

const brinkCooldown = new Map();

function tryAwaken(player, cause) {
  if (getPower(player)) return;
  if (cause === EntityDamageCause.void || cause === EntityDamageCause.selfDestruct || cause === "suicide") return;
  const hp = player.getComponent("minecraft:health");
  if (!hp || hp.currentValue <= 0 || hp.currentValue > 6) return;
  // не чаще раза в 5 секунд
  if (system.currentTick - (brinkCooldown.get(player.id) ?? -1000) < 100) return;
  brinkCooldown.set(player.id, system.currentTick);

  const n = getBrinkCount(player);
  const chance = 0.3 + n * 0.25; // 30%, 55%, 80%, 100%
  if (Math.random() < chance) {
    awaken(player);
  } else {
    setBrinkCount(player, n + 1);
    actionbar(player, "§8...что-то внутри тебя шевелится...");
    sound(player.dimension, "mob.warden.heartbeat", player.location, 1, 1);
  }
}

// ---------------------------------------------------------------- урон: пассивки и пробуждение

world.afterEvents.entityHurt.subscribe((ev) => {
  const e = ev.hurtEntity;
  if (!isValid(e)) return;
  const cause = ev.damageSource.cause;

  if (e.typeId === "minecraft:player") {
    const power = getPower(e);
    const hp = e.getComponent("minecraft:health");
    const heal = (k) => {
      try {
        if (hp.currentValue > 0) hp.setCurrentValue(Math.min(hp.effectiveMax, hp.currentValue + ev.damage * k));
      } catch {}
    };
    if (power?.id === "storm" && cause === EntityDamageCause.lightning) heal(1);
    if (power?.id === "tele" && cause === EntityDamageCause.fall) heal(1);
    if (power?.id === "grav" && cause === EntityDamageCause.fall) heal(0.5);

    // ледяная броня замораживает атакующего
    const attacker = ev.damageSource.damagingEntity;
    if (power?.id === "cryo" && attacker && (cryoArmorUntil.get(e.id) ?? 0) > system.currentTick) {
      effect(attacker, "slowness", 60, 3);
      damage(e, attacker, 2);
      particleSphere(e.dimension, "minecraft:snowflake_particle", attacker.location, 0.8, 8);
    }

    if (!power) tryAwaken(e, cause);
  }
});

// ---------------------------------------------------------------- убийства → опыт силы

world.afterEvents.entityDie.subscribe((ev) => {
  const dead = ev.deadEntity;
  let deadId;
  try {
    deadId = dead.id;
  } catch {
    return;
  }
  const hit = lastAbilityHit.get(deadId);
  lastAbilityHit.delete(deadId);

  const killer = ev.damageSource.damagingEntity;
  if (hit && system.currentTick - hit.tick < 100) {
    const p = world.getEntity(hit.playerId);
    if (!p || !isValid(p)) return;
    addXp(p, hit.hostile ? 15 : 8);
    bumpStat(p, "kills");
    if (hit.hostile) bumpStat(p, "hostile");
    if (hit.ult) bumpStat(p, "ult");
    return;
  }
  if (killer?.typeId === "minecraft:player" && getPower(killer)) addXp(killer, 3);
});

// ---------------------------------------------------------------- вход в мир

world.afterEvents.playerSpawn.subscribe((ev) => {
  const p = ev.player;
  system.runTimeout(() => {
    if (!isValid(p)) return;
    migrateItems(p);
    ensureOrb(p);
    if (getPower(p)) giveAbilityItems(p);
    if (ev.initialSpawn && !p.getDynamicProperty("aw:welcomed")) {
      p.setDynamicProperty("aw:welcomed", true);
      p.sendMessage("§6[Пробуждение] §fВ тебе дремлет сила. Она проснётся на грани смерти. Подробности — в §6Сфере Пробуждения§f.");
    }
  }, 20);
});

// ---------------------------------------------------------------- команды /scriptevent

system.afterEvents.scriptEventReceive.subscribe((ev) => {
  const p = ev.sourceEntity;
  if (!p || p.typeId !== "minecraft:player") return;
  const arg = ev.message.trim();
  switch (ev.id) {
    case "aw:admin":
      p.addTag("aw_admin");
      openAdmin(p, awaken);
      break;
    case "aw:power":
      if (POWERS[arg]) awaken(p, arg);
      else p.sendMessage("§cСилы: " + Object.keys(POWERS).join(", "));
      break;
    case "aw:reset":
      clearPower(p);
      p.sendMessage("§cСила сброшена.");
      break;
  }
});

// ---------------------------------------------------------------- игровой цикл

function heldAbility(player) {
  try {
    const it = player.getComponent("minecraft:equippable").getEquipment(EquipmentSlot.Mainhand);
    return it && ABILITY_RE.test(it.typeId) ? it.typeId : undefined;
  } catch {
    return undefined;
  }
}

// Строка над хотбаром показывается только при смене состояния (выбор предмета,
// конец перезарядки) и сама гаснет. Постоянное обновление держало на экране
// тёмную плашку, закрывавшую обзор.
const hudState = new Map(); // playerId -> ключ последнего показанного состояния

function hud(player, power) {
  const id = heldAbility(player);
  if (!id || !id.startsWith("aw:" + power.id)) {
    hudState.delete(player.id);
    return;
  }
  if ((actionbarHold.get(player.id) ?? 0) > system.currentTick) return;
  const ab = power.abilities[Number(id.slice(-1)) - 1];
  const ult = power.abilities.find((a) => a.ult);
  const left = cdLeft(player, ab.id);
  const ultReady = ult && !ab.ult && isUnlocked(player, ult) && cdLeft(player, ult.id) === 0;
  const key = `${id}|${isUnlocked(player, ab)}|${left > 0}|${ultReady}`;
  if (hudState.get(player.id) === key) return;
  hudState.set(player.id, key);

  if (!isUnlocked(player, ab)) {
    actionbar(player, `§8${ab.name}: откроется на ${ab.unlock} ур.`, false);
    return;
  }
  let text = left > 0
    ? `${power.color}${ab.name} §7| §c${Math.ceil(left / 20)} с`
    : `${power.color}${ab.name} §7| §aготово`;
  if (ultReady) text += " §6| ульта";
  actionbar(player, text, false);
}

function passives(player, power) {
  if (power.id === "pyro") {
    effect(player, "fire_resistance", 60, 0, false);
  } else if (power.id === "cryo") {
    try {
      player.removeEffect("slowness");
    } catch {}
    // «ледоход»: вода под ногами превращается в тающий лёд
    if (!player.isSneaking && !player.isSwimming) {
      const base = V.floor(player.location);
      for (let dx = -1; dx <= 1; dx++) {
        for (let dz = -1; dz <= 1; dz++) {
          const b = getBlock(player.dimension, { x: base.x + dx, y: base.y - 1, z: base.z + dz });
          if (b?.typeId === "minecraft:water" && getBlock(player.dimension, { x: base.x + dx, y: base.y, z: base.z + dz })?.isAir) {
            try {
              b.setType("minecraft:frosted_ice");
            } catch {}
          }
        }
      }
    }
  }
}

let loop = 0;
system.runInterval(() => {
  const tick = system.currentTick;
  loop++;
  for (const player of world.getAllPlayers()) {
    const power = getPower(player);
    if (!power) continue;
    hud(player, power);
    if (loop % 3 === 0) passives(player, power);
  }
  // чистка устаревших записей об ударах
  if (loop % 50 === 0) {
    for (const [id, h] of lastAbilityHit) if (tick - h.tick > 200) lastAbilityHit.delete(id);
  }
}, 4);
