import { world, system } from "@minecraft/server";

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
  floor: (a) => ({ x: Math.floor(a.x), y: Math.floor(a.y), z: Math.floor(a.z) }),
};

export function isValid(e) {
  if (!e) return false;
  try {
    return typeof e.isValid === "function" ? e.isValid() : !!e.isValid;
  } catch {
    return false;
  }
}

// Частица вплотную к камере закрывает экран, поэтому рядом с головой игроков частиц нет.
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
  for (const h of heads) if (h.dimId === dim.id && V.dist(h.loc, loc) < 2.2) return true;
  return false;
}

export function particle(dim, id, loc) {
  if (nearCamera(dim, loc)) return;
  try {
    dim.spawnParticle(id, loc);
  } catch {}
}

export function sound(dim, id, loc, pitch = 1, volume = 1) {
  try {
    dim.playSound(id, loc, { pitch, volume });
  } catch {}
}

export function actionbar(player, text) {
  try {
    player.onScreenDisplay.setActionBar(text);
  } catch {}
}

export function getBlock(dim, loc) {
  try {
    return dim.getBlock(V.floor(loc));
  } catch {
    return undefined;
  }
}

export function mainhand(player) {
  try {
    return player.getComponent("minecraft:equippable").getEquipment("Mainhand");
  } catch {
    return undefined;
  }
}

export function setMainhand(player, item) {
  try {
    player.getComponent("minecraft:equippable").setEquipment("Mainhand", item);
  } catch {}
}

export function getJson(holder, key, def) {
  const v = holder.getDynamicProperty(key);
  if (typeof v !== "string") return def;
  try {
    return JSON.parse(v);
  } catch {
    return def;
  }
}

export function setJson(holder, key, value) {
  holder.setDynamicProperty(key, value === undefined ? undefined : JSON.stringify(value));
}

export function dimName(id) {
  if (id.endsWith("nether")) return "Незер";
  if (id.endsWith("the_end")) return "Энд";
  return "Верхний мир";
}

/** Форма в 2.0 может вернуть «занят» (открыт чат и т.п.) — тогда повторяем. */
export function showForm(form, player, cb, tries = 0) {
  form.show(player).then((res) => {
    if (res.canceled) {
      if (res.cancelationReason === "UserBusy" && tries < 10) {
        system.runTimeout(() => showForm(form, player, cb, tries + 1), 10);
      }
      return;
    }
    cb(res);
  }).catch((e) => console.warn("[adventure] form: " + e));
}
