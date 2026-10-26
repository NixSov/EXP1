# Посредник Shronshiki → Supabase (Deno Deploy)

Нужен, когда у провайдера `*.supabase.co` недоступен или очень медленный
(Supabase работает через Cloudflare, а соединения с ним часть российских
операторов режет). Deno Deploy из России доступен — проверено «Проверкой
площадок» в приложении.

Пересылает только `/auth/v1/*` и `/rest/v1/*` в один проект Supabase.
`GET /health` — проверка доступности. Ключей не хранит.

## Развёртывание

Deno Deploy пока не запускает код из подпапки, поэтому `main.ts` кладётся
в отдельный репозиторий (в его корень).

1. console.deno.com → войти через GitHub → создать организацию.
2. **+ New App** → выбрать репозиторий с `main.ts` → **Create App**.
3. Настройки приложения → **Environment Variables** → **+ Add variable**:
   `SUPABASE_URL` = `https://<проект>.supabase.co`, контекст *Production* → **Save**.
4. Открыть адрес приложения + `/health` — должно быть `ok`.
5. Адрес приложения вписать в Shronshiki: **Настройки → Supabase и TURN → Посредник**
   (или `PROXY_URL` в `config/app_config.json` при сборке).

## Локальная проверка

```bash
SUPABASE_URL=https://<проект>.supabase.co deno run --allow-net --allow-env main.ts
curl http://localhost:8000/health
```

## Письма об упоминаниях (необязательно)

Раз в минуту (`Deno.cron`) посредник забирает упоминания, которые никто не увидел
в приложении за 90 секунд, и передаёт их скрипту Google Apps Script
([`mail_apps_script.gs`](mail_apps_script.gs)), который отправляет письма из Gmail.
Deno Deploy сам почту не отправляет: порты SMTP закрыты.

| Переменная | Значение |
|---|---|
| `SUPABASE_KEY` | publishable key проекта |
| `NOTIFY_SECRET` | секрет из SQL-миграции `mentions` |
| `MAIL_WEBHOOK_URL` | адрес веб-приложения Apps Script (`…/exec`) |
