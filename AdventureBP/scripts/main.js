// Модпак «Приключения»: навигатор, крюк-кошка, рюкзак, данжи.
import { world, system, ItemStack } from "@minecraft/server";
import { openMap } from "./nav.js";
import { useGrapple, tierOf, tickFallProtect } from "./grapple.js";
import { useBackpack, tickBackpacks } from "./backpack.js";
import { tickDungeons, forceDungeon } from "./dungeons.js";
import { isValid } from "./util.js";

const lastUse = new Map();

function onUse(player, item) {
  if (!item || !isValid(player)) return;
  const id = item.typeId;
  if (!id.startsWith("adv:")) return;
  // itemUse и взаимодействие с блоком могут прийти вместе — обрабатываем один раз
  if (system.currentTick - (lastUse.get(player.id) ?? -10) < 4) return;
  lastUse.set(player.id, system.currentTick);

  if (id === "adv:navigator") return openMap(player);
  if (id === "adv:backpack") return useBackpack(player);
  const tier = tierOf(id);
  if (tier) useGrapple(player, tier);
}

world.afterEvents.itemUse.subscribe((ev) => onUse(ev.source, ev.itemStack));
world.afterEvents.playerInteractWithBlock.subscribe((ev) => {
  // рюкзак и навигатор не должны срабатывать при открытии бочки/сундука
  if (ev.itemStack && ev.itemStack.typeId.startsWith("adv:grapple")) onUse(ev.player, ev.itemStack);
});

world.afterEvents.playerSpawn.subscribe((ev) => {
  if (!ev.initialSpawn) return;
  const p = ev.player;
  system.runTimeout(() => {
    if (!isValid(p) || p.getDynamicProperty("adv:welcomed")) return;
    p.setDynamicProperty("adv:welcomed", true);
    const inv = p.getComponent("minecraft:inventory")?.container;
    inv?.addItem(new ItemStack("adv:navigator", 1));
    p.sendMessage("§6[Приключения] §fТебе выдан §bНавигатор§f — карта и вейпоинты. "
      + "Крафт: крюк-кошка (палка + нитка + камень), рюкзак (кожа + нитка + сундук). "
      + "Под землёй прячутся §6данжи§f — ищи арки на поверхности.");
  }, 40);
});

system.afterEvents.scriptEventReceive.subscribe((ev) => {
  const p = ev.sourceEntity;
  if (!p || p.typeId !== "minecraft:player") return;
  if (ev.id === "adv:dungeon") forceDungeon(p, ev.message.trim());
  if (ev.id === "adv:kit") {
    const inv = p.getComponent("minecraft:inventory")?.container;
    for (const id of ["adv:navigator", "adv:backpack", "adv:grapple_5"]) inv?.addItem(new ItemStack(id, 1));
  }
});

let loop = 0;
system.runInterval(() => {
  loop++;
  tickFallProtect();
  if (loop % 5 === 0) {
    try {
      tickDungeons();
    } catch (e) {
      console.warn("[adventure] dungeons: " + e);
    }
  }
  if (loop % 20 === 0) tickBackpacks();
}, 2);
