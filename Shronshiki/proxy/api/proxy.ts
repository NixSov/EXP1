// Посредник Shronshiki на Vercel: все запросы /api/* (vercel.json перенаправляет
// их сюда) обрабатывает общий код из proxy.ts. Адрес посредника для приложения —
// https://<проект>.vercel.app/api. Переменная SUPABASE_URL — в настройках проекта.
//
// Vercel собирает proxy.ts в proxy.js и не понимает импорт с ".ts" (его требует
// только Deno), поэтому здесь путь к собранному файлу.
import { createHandler } from "../proxy.js";

declare const process: { env: Record<string, string | undefined> };

export const config = { runtime: "edge" };

const handler = createHandler(process.env.SUPABASE_URL ?? "", "/api");

export default function (req: Request): Promise<Response> {
  // Исходный путь приходит параметром __path (см. vercel.json) — восстанавливаем
  // его, чтобы запрос ушёл в Supabase по тому же адресу, что пришёл к нам.
  const url = new URL(req.url);
  const original = url.searchParams.get("__path");
  if (original !== null) {
    url.searchParams.delete("__path");
    // Vercel ещё и сам дописывает параметр маршрута (path=…) — для Supabase это
    // был бы фильтр по несуществующему столбцу.
    if (url.searchParams.get("path") === original) url.searchParams.delete("path");
    url.pathname = `/api/${original}`;
    req = new Request(url, req);
  }
  return handler(req);
}
