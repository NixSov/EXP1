// Самопроверка сервера: node test.js
import { spawn } from "node:child_process";
import assert from "node:assert/strict";
import WebSocket from "ws";

const PORT = 18000 + Math.floor(Math.random() * 1000);
const srv = spawn(process.execPath, ["server.js"], { env: { ...process.env, PORT: String(PORT) }, stdio: "ignore" });
await new Promise((r) => setTimeout(r, 500));

function connect(hello) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
    const c = { ws, json: [], bin: [] };
    ws.on("message", (d, isBin) => (isBin ? c.bin.push(Buffer.from(d)) : c.json.push(JSON.parse(d))));
    ws.on("open", () => ws.send(JSON.stringify({ t: "hello", v: 2, ...hello })));
    ws.on("error", reject);
    setTimeout(() => resolve(c), 200);
  });
}
const wait = (ms = 150) => new Promise((r) => setTimeout(r, ms));

try {
  const host = await connect({ room: "Test", name: "Хост", role: "host" });
  host.ws.send(JSON.stringify({ t: "pong", data: "cG9uZw==" }));
  await wait();
  const guest = await connect({ room: "test", name: "Гость", role: "guest" });
  const hw = host.json.find((m) => m.t === "welcome");
  const gw = guest.json.find((m) => m.t === "welcome");
  assert.equal(gw.hostId, hw.id);
  assert.equal(gw.pong, "cG9uZw==");
  assert.ok(host.json.some((m) => m.t === "join" && m.name === "Гость"));

  // второй хост не допускается
  const host2 = await connect({ room: "test", name: "X", role: "host" });
  assert.ok(host2.json.some((m) => m.t === "error"));

  // голос
  guest.ws.send(Buffer.from([1, 9, 8, 7]));
  await wait();
  const v = host.bin.find((b) => b[0] === 1);
  assert.equal(v.readUInt16BE(1), gw.id);
  assert.deepEqual([...v.subarray(3)], [9, 8, 7]);

  // туннель гость -> хост -> гость
  guest.ws.send(Buffer.from([2, 0, 5, 0xaa, 0xbb]));
  await wait();
  const g = host.bin.find((b) => b[0] === 2);
  assert.equal(g.readUInt16BE(1), gw.id);
  assert.equal(g.readUInt16BE(3), 5);
  assert.deepEqual([...g.subarray(5)], [0xaa, 0xbb]);
  const reply = Buffer.from([3, 0, 0, 0, 5, 0xcc]);
  reply.writeUInt16BE(gw.id, 1);
  host.ws.send(reply);
  await wait();
  const r = guest.bin.find((b) => b[0] === 3);
  assert.deepEqual([...r], [3, 0, 5, 0xcc]);

  // уход хоста
  host.ws.close();
  await wait();
  assert.ok(guest.json.some((m) => m.t === "leave" && m.id === hw.id));
  console.log("OK: все проверки сервера пройдены");
  for (const c of [guest, host2]) c.ws.close();
} finally {
  srv.kill();
}
