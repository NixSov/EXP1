// Посредник Shronshiki на Vercel: все запросы /api/* обрабатывает общий код
// из proxy.ts. Адрес посредника для приложения — https://<проект>.vercel.app/api
// Переменная окружения SUPABASE_URL задаётся в настройках проекта Vercel.
import { createHandler } from "../proxy.ts";

declare const process: { env: Record<string, string | undefined> };

export const config = { runtime: "edge" };

export default createHandler(process.env.SUPABASE_URL ?? "", "/api");
