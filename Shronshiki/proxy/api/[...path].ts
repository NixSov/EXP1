// Посредник Shronshiki на Vercel: все запросы /api/* обрабатывает общий код
// из proxy.ts. Адрес посредника для приложения — https://<проект>.vercel.app/api
// Переменная окружения SUPABASE_URL задаётся в настройках проекта Vercel.
// Vercel собирает proxy.ts в proxy.js и не понимает импорт с ".ts" (его требует
// только Deno), поэтому здесь путь к собранному файлу.
import { createHandler } from "../proxy.js";

declare const process: { env: Record<string, string | undefined> };

export const config = { runtime: "edge" };

export default createHandler(process.env.SUPABASE_URL ?? "", "/api");
