// Ретранслятор «MC Вместе»: голосовой чат и туннель к миру Minecraft хоста.
//
// В комнате один хост (телефон, на котором открыт мир) и гости. Сервер:
//   • пересылает голос всем участникам комнаты (слышно на любом расстоянии);
//   • пересылает UDP-пакеты Minecraft (RakNet) между гостями и хостом;
//   • раздаёт гостям «визитку» мира хоста (ответ на LAN-пинг).
//
// Текстовые сообщения (JSON):
//   клиент -> сервер: {"t":"hello","room","name","role":"host"|"guest","muted","v":2}
//                     {"t":"mute","muted"}   {"t":"pong","data":base64}  (только хост)
//   сервер -> клиент: {"t":"welcome","id","hostId","members":[{id,name,muted,host}],"pong"}
//                     {"t":"join",...} {"t":"leave","id"} {"t":"mute","id","muted"}
//                     {"t":"pong","data"} {"t":"error","message"}
// Двоичные сообщения (первый байт — тип):
//   0x01 голос:   клиент -> [01][аудио];               сервер -> [01][id u16][аудио]
//   0x02 игра:    гость  -> [02][sid u16][udp];        сервер -> хосту [02][guest u16][sid u16][udp]
//   0x03 игра:    хост   -> [03][guest u16][sid u16][udp]; сервер -> гостю [03][sid u16][udp]
import http from "node:http";
import { WebSocketServer } from "ws";

const PORT = Number(process.env.PORT) || 8080;
const MAX_ROOM = 16;
const PROTOCOL_VERSION = 2;
const MAX_BUFFERED = 512 * 1024;

const rooms = new Map(); // код -> { clients: Map<id, client>, host: client|null, pong: string|null }
let nextId = 1;

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

const server = http.createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
  let people = 0;
  for (const r of rooms.values()) people += r.clients.size;
  res.end(`MC Вместе: сервер работает. Комнат: ${rooms.size}, участников: ${people}\n`);
});

const wss = new WebSocketServer({ server, maxPayload: 256 * 1024 });

function sendJson(c, obj) {
  if (c.ws.readyState === c.ws.OPEN) c.ws.send(JSON.stringify(obj));
}

function sendBin(c, buf) {
  if (c.ws.readyState === c.ws.OPEN && c.ws.bufferedAmount < MAX_BUFFERED) c.ws.send(buf, { binary: true });
}

function broadcast(room, except, obj) {
  for (const c of room.clients.values()) if (c !== except) sendJson(c, obj);
}

function cleanText(s, max) {
  return String(s ?? "").replace(/[\u0000-\u001f]/g, "").trim().slice(0, max);
}

function memberInfo(c) {
  return { id: c.id, name: c.name, muted: c.muted, host: c.role === "host" };
}

function allocId(room) {
  do nextId = (nextId % 65000) + 1;
  while (room.clients.has(nextId));
  return nextId;
}

function onHello(client, msg) {
  const code = cleanText(msg.room, 32).toLowerCase();
  const name = cleanText(msg.name, 24) || "Игрок";
  const role = msg.role === "host" ? "host" : "guest";
  if (msg.v !== PROTOCOL_VERSION) return sendJson(client, { t: "error", message: "Обнови приложение или сервер" });
  if (!code) return sendJson(client, { t: "error", message: "Пустой код комнаты" });
  let room = rooms.get(code);
  if (!room) rooms.set(code, (room = { clients: new Map(), host: null, pong: null }));
  if (room.clients.size >= MAX_ROOM) return sendJson(client, { t: "error", message: "Комната заполнена" });
  if (role === "host" && room.host) return sendJson(client, { t: "error", message: "В этой комнате уже есть хост" });

  client.id = allocId(room);
  client.name = name;
  client.role = role;
  client.muted = !!msg.muted;
  client.room = room;
  client.code = code;
  room.clients.set(client.id, client);
  if (role === "host") room.host = client;

  sendJson(client, {
    t: "welcome",
    id: client.id,
    hostId: room.host ? room.host.id : null,
    members: [...room.clients.values()].filter((c) => c !== client).map(memberInfo),
    pong: role === "guest" ? room.pong : null,
  });
  broadcast(room, client, { t: "join", ...memberInfo(client) });
  log(`+ ${name} (${role}) -> "${code}" [${room.clients.size}]`);
}

function onBinary(client, data) {
  const room = client.room;
  if (!room || data.length < 2) return;
  const type = data[0];

  if (type === 0x01) {
    if (client.muted || data.length > 4000) return;
    const out = Buffer.allocUnsafe(data.length + 2);
    out[0] = 0x01;
    out.writeUInt16BE(client.id, 1);
    data.copy(out, 3, 1);
    for (const c of room.clients.values()) if (c !== client) sendBin(c, out);
  } else if (type === 0x02 && client.role === "guest" && room.host && data.length >= 3) {
    const out = Buffer.allocUnsafe(data.length + 2);
    out[0] = 0x02;
    out.writeUInt16BE(client.id, 1);
    data.copy(out, 3, 1);
    sendBin(room.host, out);
  } else if (type === 0x03 && client.role === "host" && data.length >= 5) {
    const guest = room.clients.get(data.readUInt16BE(1));
    if (!guest) return;
    const out = Buffer.allocUnsafe(data.length - 2);
    out[0] = 0x03;
    data.copy(out, 1, 3);
    sendBin(guest, out);
  }
}

wss.on("connection", (ws) => {
  const client = { ws, id: 0, name: "", role: "guest", room: null, code: "", muted: false, alive: true };
  ws.client = client;
  ws.on("pong", () => (client.alive = true));

  ws.on("message", (data, isBinary) => {
    if (isBinary) return onBinary(client, data);
    let msg;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      return;
    }
    if (msg.t === "hello" && !client.room) onHello(client, msg);
    else if (!client.room) return;
    else if (msg.t === "mute") {
      client.muted = !!msg.muted;
      broadcast(client.room, client, { t: "mute", id: client.id, muted: client.muted });
    } else if (msg.t === "pong" && client.role === "host" && typeof msg.data === "string" && msg.data.length < 2000) {
      if (client.room.pong !== msg.data) {
        client.room.pong = msg.data;
        broadcast(client.room, client, { t: "pong", data: msg.data });
      }
    }
  });

  ws.on("close", () => {
    const room = client.room;
    if (!room) return;
    room.clients.delete(client.id);
    if (room.host === client) {
      room.host = null;
      room.pong = null;
    }
    broadcast(room, client, { t: "leave", id: client.id });
    if (!room.clients.size) rooms.delete(client.code);
    log(`- ${client.name} <- "${client.code}" [${room.clients.size}]`);
  });

  ws.on("error", () => {});
});

// Обрываем «мёртвые» соединения (телефон ушёл из сети).
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.client.alive) {
      ws.terminate();
      continue;
    }
    ws.client.alive = false;
    try {
      ws.ping();
    } catch {}
  }
}, 20000);

server.listen(PORT, () => log(`MC Вместе: сервер слушает порт ${PORT}`));
