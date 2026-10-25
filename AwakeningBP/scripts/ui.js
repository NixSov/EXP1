import { system } from "@minecraft/server";
import { ActionFormData, MessageFormData } from "@minecraft/server-ui";
import { POWERS } from "./defs.js";
import {
  getPower, getLevel, getXp, xpForNext, getSkillPoints, getRank, isUnlocked, upgradeAbility, cooldownTicks,
  giveAbilityItems, currentQuest, questProgress, claimQuest, QUESTS, getQuestIndex, MAX_RANK, MAX_LEVEL,
  clearPower, setLevel, addSkillPoints, getStats,
} from "./data.js";

const ORB_ICON = "textures/items/aw/awakening_orb";

function bar(cur, max, len = 20) {
  const n = Math.max(0, Math.min(len, Math.round((cur / max) * len)));
  return "§a" + "|".repeat(n) + "§8" + "|".repeat(len - n);
}

function show(form, player, cb) {
  form.show(player).then((res) => {
    if (res.canceled) return;
    cb(res);
  }).catch((e) => console.warn("[awakening] form: " + e));
}

// ---------------------------------------------------------------- главное меню

export function openMainMenu(player) {
  const power = getPower(player);
  if (!power) return openNotAwakened(player);

  const level = getLevel(player);
  const xpText = level >= MAX_LEVEL ? "§6МАКС." : `${getXp(player)}/${xpForNext(level)}`;
  const q = currentQuest(player);
  const questReady = q && questProgress(player, q) >= q.goal;

  const body = [
    `§fСила: ${power.color}§l${power.name}§r`,
    `§fУровень: §e${level}  §7(опыт ${xpText})`,
    level < MAX_LEVEL ? bar(getXp(player), xpForNext(level)) : "",
    `§fОчки навыков: §b${getSkillPoints(player)}`,
    `§fПассивно: §7${power.passive}`,
  ].join("\n");

  const form = new ActionFormData()
    .title("§l§6ПРОБУЖДЕНИЕ")
    .body(body)
    .button("§lСпособности\n§r§8прокачка и описание", power.abilities[0].icon)
    .button("§lВзять предметы\n§r§8способностей в хотбар", power.abilities[1].icon)
    .button(`§lЗадания${questReady ? " §a(!)" : ""}\n§r§8${q ? q.name : "все выполнены"}`, "textures/items/book_writable")
    .button("§lСправка\n§r§8как играть", "textures/items/book_normal");

  show(form, player, (res) => {
    switch (res.selection) {
      case 0: return openAbilities(player);
      case 1: {
        const n = giveAbilityItems(player);
        player.sendMessage(n ? `§aВыдано предметов: ${n}` : "§7Все открытые способности уже у тебя в инвентаре.");
        return;
      }
      case 2: return openQuests(player);
      case 3: return openHelp(player, true);
    }
  });
}

function openNotAwakened(player) {
  const form = new ActionFormData()
    .title("§l§6ПРОБУЖДЕНИЕ")
    .body([
      "§7Твоя сила ещё спит...",
      "",
      "§fСила пробуждается, когда ты оказываешься §cна грани смерти§f:",
      "§7получи урон, оставшись с §c3 сердцами§7 или меньше.",
      "§7Каждый такой раз увеличивает шанс пробуждения.",
      "",
      "§8Возможные силы: " + Object.values(POWERS).map((p) => p.color + p.name).join("§8, "),
    ].join("\n"))
    .button("§lСправка", "textures/items/book_normal")
    .button("§lЗакрыть", ORB_ICON);
  show(form, player, (res) => {
    if (res.selection === 0) openHelp(player, false);
  });
}

// ---------------------------------------------------------------- способности

function openAbilities(player) {
  const power = getPower(player);
  if (!power) return;
  const form = new ActionFormData()
    .title(`${power.color}${power.name}`)
    .body(`§fОчки навыков: §b${getSkillPoints(player)}\n§7Выбери способность для прокачки.`);
  for (const ab of power.abilities) {
    const label = isUnlocked(player, ab)
      ? `${power.color}§l${ab.name}§r\n§8ранг ${getRank(player, ab.index)}/${MAX_RANK}`
      : `§8§l${ab.name}§r\n§8откроется на ${ab.unlock} ур.`;
    form.button(label, ab.icon);
  }
  form.button("§lНазад", ORB_ICON);
  show(form, player, (res) => {
    if (res.selection === power.abilities.length) return openMainMenu(player);
    openAbility(player, power.abilities[res.selection]);
  });
}

function openAbility(player, ab) {
  const power = getPower(player);
  const rank = getRank(player, ab.index);
  const unlocked = isUnlocked(player, ab);
  const sp = getSkillPoints(player);
  const cost = rank;
  const lines = [
    `§f${ab.desc}`,
    "",
    `§7Перезарядка: §f${(cooldownTicks(player, ab) / 20).toFixed(1)} с`,
    `§7Ранг: §e${rank}/${MAX_RANK}  §7(+15% урона и -8% перезарядки за ранг)`,
    ab.ult ? "§6Ульта: §7её также можно применить, присев и нажав любой предмет силы." : "",
    !unlocked ? `§cОткроется на ${ab.unlock} уровне.` : "",
  ];
  const form = new MessageFormData()
    .title(`${power.color}${ab.name}`)
    .body(lines.filter((l) => l !== "").join("\n"))
    .button1(unlocked && rank < MAX_RANK ? `Улучшить (${cost} оч., есть ${sp})` : "Улучшить нельзя")
    .button2("Назад");
  show(form, player, (res) => {
    if (res.selection === 0 && unlocked && rank < MAX_RANK) {
      if (upgradeAbility(player, ab.index)) {
        player.sendMessage(`§a${ab.name} улучшена до ранга ${rank + 1}!`);
        player.playSound("random.levelup", { pitch: 1.5 });
      } else {
        player.sendMessage("§cНе хватает очков навыков.");
      }
      return system.run(() => openAbility(player, ab));
    }
    openAbilities(player);
  });
}

// ---------------------------------------------------------------- задания

function openQuests(player) {
  const idx = getQuestIndex(player);
  const q = currentQuest(player);
  const stats = getStats(player);
  const lines = [];
  QUESTS.forEach((it, i) => {
    if (i < idx) lines.push(`§a[+] ${it.name}`);
    else if (i === idx) lines.push(`§e[>] ${it.name}: §f${it.desc} §7(${Math.min(questProgress(player, it), it.goal)}/${it.goal})`);
    else lines.push(`§8[ ] ${it.name}`);
  });
  lines.push("", `§7Всего: применений ${stats.uses ?? 0}, убийств ${stats.kills ?? 0}`);
  const ready = q && questProgress(player, q) >= q.goal;
  const reward = q ? `${q.xp ? q.xp + " опыта " : ""}${q.sp ? "+" + q.sp + " оч. навыков " : ""}${q.diamonds ? "+" + q.diamonds + " алмазов" : ""}` : "";
  const form = new ActionFormData().title("§lЗадания").body(lines.join("\n"));
  if (ready) form.button(`§a§lЗабрать награду\n§r§2${reward}`, "textures/items/diamond");
  form.button("§lНазад", ORB_ICON);
  show(form, player, (res) => {
    if (ready && res.selection === 0) {
      claimQuest(player);
      player.sendMessage(`§aНаграда получена: ${reward}`);
      return system.run(() => openQuests(player));
    }
    openMainMenu(player);
  });
}

// ---------------------------------------------------------------- справка

function openHelp(player, back) {
  const form = new MessageFormData()
    .title("§lКак играть")
    .body([
      "§6Пробуждение",
      "§7Окажись на грани смерти (3 сердца и меньше), и сила может пробудиться.",
      "",
      "§6Управление (телефон)",
      "§f• Каждая способность — отдельный предмет. Выбери его в хотбаре и нажми «Использовать» (тап по экрану или кнопка).",
      "§f• Присядь и нажми любой предмет силы — сработает §6ульта§f (если открыта).",
      "§f• Перезарядку видно на иконке и в строке над хотбаром.",
      "§f• Сфера Пробуждения открывает это меню.",
      "",
      "§6Прокачка",
      "§7Опыт силы — за убийства способностями. За уровень — очко навыка. Очки тратятся на ранги способностей. Новые способности открываются на 3, 5 и 8 уровнях.",
      "",
      "§6Смена силы",
      "§7Используй §5Осколок Забвения§7: сила и прогресс сбросятся, а следующее пробуждение даст новую силу.",
    ].join("\n"))
    .button1("Понятно")
    .button2("Назад");
  show(form, player, (res) => {
    if (res.selection === 1 && back) openMainMenu(player);
  });
}

// ---------------------------------------------------------------- осколок забвения

export function openOblivion(player, onConfirm) {
  const power = getPower(player);
  if (!power) {
    player.sendMessage("§7У тебя ещё нет силы, которую можно забыть.");
    return;
  }
  const form = new MessageFormData()
    .title("§5Осколок Забвения")
    .body(`§fЗабыть силу ${power.color}${power.name}§f?\n\n§cУровень, ранги и задания будут сброшены. Новая сила пробудится на грани смерти.`)
    .button1("§cЗабыть силу")
    .button2("Отмена");
  show(form, player, (res) => {
    if (res.selection === 0) onConfirm();
  });
}

// ---------------------------------------------------------------- админ

export function openAdmin(player, awaken) {
  const form = new ActionFormData().title("§cАдмин: Пробуждение").body("§7Управление силой для себя.");
  const powers = Object.values(POWERS);
  for (const p of powers) form.button(`${p.color}Дать: ${p.name}`, p.abilities[0].icon);
  form.button("§e+5 уровней");
  form.button("§b+10 очков навыков");
  form.button("§aМаксимальный уровень");
  form.button("§cСбросить всё");
  show(form, player, (res) => {
    const s = res.selection;
    if (s < powers.length) return awaken(player, powers[s].id);
    switch (s - powers.length) {
      case 0: return setLevel(player, getLevel(player) + 5);
      case 1: return addSkillPoints(player, 10);
      case 2: return setLevel(player, MAX_LEVEL);
      case 3:
        clearPower(player);
        player.sendMessage("§cСила сброшена.");
        return;
    }
  });
}

