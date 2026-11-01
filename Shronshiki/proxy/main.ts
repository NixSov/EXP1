// Shronshiki: посредник к Supabase для сетей, где supabase.co недоступен
// (часть российских провайдеров режет соединения с Cloudflare, через который
// работает Supabase). Запускается на Deno Deploy — его серверы из России доступны.
//
// Пересылает только запросы входа (/auth/v1/) и базы (/rest/v1/) в один проект
// Supabase — это не открытый прокси. Ключи посредник не хранит: приложение само
// передаёт свой publishable/anon key в заголовке, как и при прямом подключении.
//
// Адрес проекта задаётся переменной окружения SUPABASE_URL
// (Deno Deploy → Settings → Environment Variables).

import { createHandler } from "./proxy.ts";

export { githubTarget } from "./proxy.ts";

Deno.serve(createHandler(Deno.env.get("SUPABASE_URL") ?? ""));
