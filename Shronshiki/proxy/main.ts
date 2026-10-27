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

// Обновления приложения: список выпусков и файлы из GitHub одного репозитория.
// Нужно, если github.com у провайдера не открывается.
const GITHUB_REPO = "NixSov/EXP1";
const RELEASE_TAG = /^shronshiki-b\d+$/;
const RELEASE_FILE = /^Shronshiki[\w.-]*\.(apk|exe)$/;

/** /gh/releases и /gh/download/<тег>/<файл> → GitHub. null — путь не про GitHub. */
export function githubTarget(pathname: string): string | null | undefined {
  if (pathname === "/gh/releases") {
    return `https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=20`;
  }
  const m = pathname.match(/^\/gh\/download\/([^/]+)\/([^/]+)$/);
  if (m) {
    if (!RELEASE_TAG.test(m[1]) || !RELEASE_FILE.test(m[2])) return undefined;
    return `https://github.com/${GITHUB_REPO}/releases/download/${m[1]}/${m[2]}`;
  }
  return pathname.startsWith("/gh/") ? undefined : null;
}

async function proxyGithub(target: string): Promise<Response> {
  // Таймаут только на ответ: сам файл (десятки МБ) может идти дольше.
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 25_000);
  try {
    const upstream = await fetch(target, {
      headers: { accept: "application/vnd.github+json", "user-agent": "shronshiki-proxy" },
      signal: abort.signal,
    });
    clearTimeout(timer);
    const out = new Headers();
    for (const name of ["content-type", "content-length", "content-disposition"]) {
      const value = upstream.headers.get(name);
      if (value && !(name === "content-length" && upstream.headers.get("content-encoding"))) {
        out.set(name, value);
      }
    }
    return new Response(upstream.body, { status: upstream.status, headers: out });
  } catch (e) {
    clearTimeout(timer);
    return new Response(`upstream error: ${e instanceof Error ? e.message : e}`, { status: 502 });
  }
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // Проверка доступности посредника из приложения.
  if (url.pathname === "/health") {
    return new Response(TARGET ? "ok" : "SUPABASE_URL is not set", {
      status: TARGET ? 200 : 500,
      headers: { "cache-control": "no-store" },
    });
  }
  const github = githubTarget(url.pathname);
  if (github === undefined) return new Response("not found", { status: 404 });
  if (github !== null) return await proxyGithub(github);

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
