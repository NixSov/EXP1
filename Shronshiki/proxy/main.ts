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

const TARGET = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
const ALLOWED_PREFIXES = ["/auth/v1/", "/rest/v1/"];

// Заголовки соединения не пересылаем — fetch выставит свои.
const DROP_REQUEST_HEADERS = [
  "host",
  "connection",
  "keep-alive",
  "proxy-connection",
  "transfer-encoding",
  "upgrade",
  "te",
  "trailer",
  "content-length",
  "accept-encoding",
];

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // Проверка доступности посредника из приложения.
  if (url.pathname === "/health") {
    return new Response(TARGET ? "ok" : "SUPABASE_URL is not set", {
      status: TARGET ? 200 : 500,
      headers: { "cache-control": "no-store" },
    });
  }
  if (!TARGET) return new Response("SUPABASE_URL is not set", { status: 500 });
  if (!ALLOWED_PREFIXES.some((p) => url.pathname.startsWith(p))) {
    return new Response("not found", { status: 404 });
  }

  const headers = new Headers(req.headers);
  for (const name of DROP_REQUEST_HEADERS) headers.delete(name);

  try {
    const hasBody = req.method !== "GET" && req.method !== "HEAD";
    const upstream = await fetch(TARGET + url.pathname + url.search, {
      method: req.method,
      headers,
      body: hasBody ? await req.arrayBuffer() : undefined,
      redirect: "manual",
      signal: AbortSignal.timeout(25_000),
    });
    // fetch уже распаковал тело, поэтому заголовки сжатия и длины убираем.
    const out = new Headers(upstream.headers);
    for (const name of ["content-encoding", "content-length", "transfer-encoding", "connection"]) {
      out.delete(name);
    }
    return new Response(upstream.body, { status: upstream.status, headers: out });
  } catch (e) {
    return new Response(`upstream error: ${e instanceof Error ? e.message : e}`, { status: 502 });
  }
});
