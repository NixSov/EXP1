// Shronshiki: посредник к Supabase на Google Apps Script — для сетей, где
// недоступны и supabase.co, и Vercel. Google из России открывается стабильно.
//
// Apps Script не отдаёт скрипту заголовки запроса, поэтому приложение
// «упаковывает» запрос в JSON: {m: метод, p: путь, q: строка параметров,
// h: заголовки, b: тело} и шлёт его POST-ом на адрес веб-приложения. Ответ —
// тоже JSON: {s: код ответа, h: заголовки, b: тело}.
//
// Пересылает только /auth/v1/ и /rest/v1/ в один проект Supabase. Ключей не
// хранит: приложение передаёт свой publishable key, как и при прямом подключении.
//
// Развёртывание: script.google.com → Новый проект → вставить этот файл →
// Начать развертывание → Новое развертывание → Веб-приложение → Запуск от имени:
// Я, У кого есть доступ: Все → Развернуть → разрешить доступ. Адрес веб-приложения
// (…/exec) добавить в список посредников приложения.
//
// Лимит Google для обычного аккаунта — 20 000 запросов к внешним адресам в сутки.

const SUPABASE_URL = 'https://ovnrfrnnwbudulugxkia.supabase.co';
const ALLOWED_PREFIXES = ['/auth/v1/', '/rest/v1/'];

// Какие заголовки пересылать в Supabase и обратно.
const REQUEST_HEADERS = ['apikey', 'authorization', 'accept', 'prefer', 'accept-profile',
  'content-profile', 'x-client-info', 'x-supabase-api-version'];
const RESPONSE_HEADERS = ['content-type', 'content-range', 'x-supabase-api-version'];

/** GET …/exec — проверка доступности (…/exec/health Google без входа не открывает). */
function doGet(e) {
  return reply_({ s: 200, h: { 'content-type': 'text/plain' }, b: 'ok' });
}

function doPost(e) {
  let req;
  try {
    req = JSON.parse(e.postData.contents);
  } catch (err) {
    return reply_({ s: 400, h: {}, b: 'bad envelope' });
  }
  const path = String(req.p || '');
  if (path === '/health') return doGet(e);
  if (!ALLOWED_PREFIXES.some(function (p) { return path.indexOf(p) === 0; })) {
    return reply_({ s: 404, h: {}, b: 'not found' });
  }
  const method = String(req.m || 'GET').toLowerCase();
  const inHeaders = req.h || {};
  const headers = {};
  REQUEST_HEADERS.forEach(function (name) {
    if (inHeaders[name] != null) headers[name] = String(inHeaders[name]);
  });
  const options = { method: method, headers: headers, muteHttpExceptions: true, followRedirects: false };
  if (req.b != null && method !== 'get' && method !== 'head') {
    options.payload = String(req.b);
    options.contentType = String(inHeaders['content-type'] || 'application/json');
  }
  const url = SUPABASE_URL + path + (req.q ? '?' + req.q : '');
  let res;
  try {
    res = UrlFetchApp.fetch(url, options);
  } catch (err) {
    return reply_({ s: 502, h: {}, b: 'upstream error: ' + err });
  }
  const all = res.getAllHeaders();
  const outHeaders = {};
  Object.keys(all).forEach(function (name) {
    if (RESPONSE_HEADERS.indexOf(name.toLowerCase()) >= 0) outHeaders[name.toLowerCase()] = String(all[name]);
  });
  return reply_({ s: res.getResponseCode(), h: outHeaders, b: res.getContentText() });
}

function reply_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
