// Русские названия частых предметов. Script API 2.0 не даёт перевод названия предмета,
// поэтому для остальных показываем аккуратно оформленный идентификатор.
const RU = {
  diamond: "Алмаз", emerald: "Изумруд", iron_ingot: "Железный слиток", gold_ingot: "Золотой слиток",
  copper_ingot: "Медный слиток", netherite_ingot: "Незеритовый слиток", netherite_scrap: "Незеритовый лом",
  coal: "Уголь", charcoal: "Древесный уголь", redstone: "Редстоун", lapis_lazuli: "Лазурит", quartz: "Кварц",
  amethyst_shard: "Осколок аметиста", raw_iron: "Рудное железо", raw_gold: "Рудное золото", raw_copper: "Рудная медь",
  iron_nugget: "Кусочек железа", gold_nugget: "Кусочек золота", flint: "Кремень", stick: "Палка", string: "Нитка",
  leather: "Кожа", feather: "Перо", bone: "Кость", bone_meal: "Костная мука", gunpowder: "Порох",
  slime_ball: "Слизь", ender_pearl: "Жемчуг Края", ender_eye: "Око Края", blaze_rod: "Огненный стержень",
  blaze_powder: "Огненный порошок", spider_eye: "Паучий глаз", rotten_flesh: "Гнилая плоть", paper: "Бумага",
  book: "Книга", enchanted_book: "Зачарованная книга", experience_bottle: "Пузырёк опыта", arrow: "Стрела",
  clay_ball: "Комок глины", brick: "Кирпич", glass_bottle: "Бутылочка", bucket: "Ведро", water_bucket: "Ведро воды",
  lava_bucket: "Ведро лавы", milk_bucket: "Ведро молока", compass: "Компас", clock: "Часы", map: "Карта",
  filled_map: "Карта", torch: "Факел", saddle: "Седло", name_tag: "Бирка", lead: "Поводок",
  totem_of_undying: "Тотем бессмертия", shield: "Щит", bow: "Лук", crossbow: "Арбалет", trident: "Трезубец",
  fishing_rod: "Удочка", shears: "Ножницы", flint_and_steel: "Огниво", elytra: "Элитры",
  apple: "Яблоко", golden_apple: "Золотое яблоко", enchanted_golden_apple: "Зачарованное золотое яблоко",
  bread: "Хлеб", wheat: "Пшеница", wheat_seeds: "Семена пшеницы", carrot: "Морковь", potato: "Картофель",
  baked_potato: "Печёный картофель", beetroot: "Свёкла", melon_slice: "Ломтик арбуза", sugar: "Сахар",
  cooked_beef: "Стейк", beef: "Сырая говядина", cooked_porkchop: "Жареная свинина", porkchop: "Сырая свинина",
  cooked_chicken: "Жареная курица", chicken: "Сырая курица", cooked_mutton: "Жареная баранина", mutton: "Сырая баранина",
  cooked_cod: "Жареная треска", cod: "Сырая треска", cooked_salmon: "Жареный лосось", salmon: "Сырой лосось",
  cookie: "Печенье", pumpkin_pie: "Тыквенный пирог", golden_carrot: "Золотая морковь", egg: "Яйцо",
  cobblestone: "Булыжник", stone: "Камень", dirt: "Земля", grass_block: "Блок травы", sand: "Песок",
  gravel: "Гравий", deepslate: "Глубинный сланец", cobbled_deepslate: "Глубинный булыжник", andesite: "Андезит",
  diorite: "Диорит", granite: "Гранит", tuff: "Туф", netherrack: "Незерак", blackstone: "Чернокамень",
  obsidian: "Обсидиан", glass: "Стекло", sandstone: "Песчаник", snow: "Снег", ice: "Лёд", packed_ice: "Плотный лёд",
  oak_log: "Дубовое бревно", spruce_log: "Еловое бревно", birch_log: "Берёзовое бревно", jungle_log: "Бревно тропического дерева",
  acacia_log: "Акациевое бревно", dark_oak_log: "Бревно тёмного дуба", cherry_log: "Вишнёвое бревно",
  oak_planks: "Дубовые доски", spruce_planks: "Еловые доски", birch_planks: "Берёзовые доски",
  crafting_table: "Верстак", furnace: "Печь", chest: "Сундук", barrel: "Бочка", ladder: "Лестница",
  iron_block: "Железный блок", gold_block: "Золотой блок", diamond_block: "Алмазный блок", emerald_block: "Изумрудный блок",
  coal_ore: "Угольная руда", iron_ore: "Железная руда", gold_ore: "Золотая руда", diamond_ore: "Алмазная руда",
  tnt: "Динамит", wool: "Шерсть", white_wool: "Белая шерсть", bed: "Кровать",
  "adv:navigator": "Навигатор", "adv:backpack": "Рюкзак",
};

const MATERIALS = {
  wooden: "Деревянн", stone: "Каменн", iron: "Железн", golden: "Золот", diamond: "Алмазн", netherite: "Незеритов",
  leather: "Кожан", chainmail: "Кольчужн",
};
const TOOLS = {
  sword: ["ый меч", "м"], pickaxe: ["ая кирка", "ж"], axe: ["ый топор", "м"], shovel: ["ая лопата", "ж"],
  hoe: ["ая мотыга", "ж"], helmet: ["ый шлем", "м"], chestplate: ["ый нагрудник", "м"],
  leggings: ["ые поножи", "мн"], boots: ["ые ботинки", "мн"],
};

export function itemName(typeId) {
  const id = typeId.startsWith("minecraft:") ? typeId.slice(10) : typeId;
  if (RU[id]) return RU[id];
  if (RU[typeId]) return RU[typeId];
  const m = id.match(/^(wooden|stone|iron|golden|diamond|netherite|leather|chainmail)_(sword|pickaxe|axe|shovel|hoe|helmet|chestplate|leggings|boots)$/);
  if (m) {
    let stem = MATERIALS[m[1]];
    let end = TOOLS[m[2]][0];
    // «Золотой», «Каменный» — у основы своё окончание
    if (m[1] === "golden" && end.startsWith("ый")) end = "ой" + end.slice(2);
    return stem + end;
  }
  const g = id.match(/^adv:grapple_(\d)$/) || typeId.match(/^adv:grapple_(\d)$/);
  if (g) return "Крюк-кошка " + ["I", "II", "III", "IV", "V"][Number(g[1]) - 1];
  const words = id.replace(/^[a-z_]+:/, "").split("_");
  const s = words.join(" ");
  return s.charAt(0).toUpperCase() + s.slice(1);
}
