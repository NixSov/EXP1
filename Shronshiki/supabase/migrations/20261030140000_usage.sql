-- Расход бесплатных лимитов за месяц: сколько трафика прошло через TURN и сколько
-- запросов — через посредника. Приложения сами считают свой расход во время
-- звонка и раз в минуту присылают прибавку (report_usage). В настройках по этим
-- цифрам показывается, сколько часов разговора осталось (usage_summary).
--
-- Лимиты можно поменять без обновления приложения, например:
--   update public.usage_limits set monthly_limit = 1000e9 where key = 'turn_bytes';

create table if not exists public.usage_limits (
  key           text primary key,
  title         text not null,
  monthly_limit numeric not null,
  -- Расход на час разговора одного участника, пока своих замеров мало.
  default_rate  numeric not null
);

insert into public.usage_limits (key, title, monthly_limit, default_rate) values
  ('turn_bytes', 'TURN (ExpressTURN)', 1000e9, 30e6),
  ('proxy_requests', 'Посредник (Vercel)', 1000000, 720)
on conflict (key) do nothing;

create table if not exists public.usage_monthly (
  month          date primary key,
  seconds        bigint not null default 0,  -- время в звонках, сумма по участникам
  turn_seconds   bigint not null default 0,  -- из них со связью через TURN
  proxy_seconds  bigint not null default 0,  -- из них через посредника
  turn_bytes     bigint not null default 0,
  proxy_requests bigint not null default 0
);

alter table public.usage_limits enable row level security;
alter table public.usage_monthly enable row level security;
revoke all on public.usage_limits, public.usage_monthly from anon, authenticated;

create or replace function public.report_usage(
  p_seconds int,
  p_turn_seconds int,
  p_proxy_seconds int,
  p_turn_bytes bigint,
  p_proxy_requests int
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  -- Отсекаем явный мусор: прибавка присылается раз в минуту.
  if p_seconds < 0 or p_seconds > 3600 or p_turn_seconds < 0 or p_proxy_seconds < 0
     or p_turn_bytes < 0 or p_turn_bytes > 2e9 or p_proxy_requests < 0 or p_proxy_requests > 5000 then
    raise exception 'bad usage report';
  end if;
  insert into public.usage_monthly as u
    (month, seconds, turn_seconds, proxy_seconds, turn_bytes, proxy_requests)
  values (date_trunc('month', now())::date, p_seconds, least(p_turn_seconds, p_seconds),
          least(p_proxy_seconds, p_seconds), p_turn_bytes, p_proxy_requests)
  on conflict (month) do update set
    seconds        = u.seconds + excluded.seconds,
    turn_seconds   = u.turn_seconds + excluded.turn_seconds,
    proxy_seconds  = u.proxy_seconds + excluded.proxy_seconds,
    turn_bytes     = u.turn_bytes + excluded.turn_bytes,
    proxy_requests = u.proxy_requests + excluded.proxy_requests;
end;
$$;

-- Сколько осталось: по каждому лимиту — расход, лимит и часы разговора одного
-- участника, на которые хватит остатка (по своим замерам, если их уже больше часа).
create or replace function public.usage_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  m public.usage_monthly;
  result jsonb := '[]'::jsonb;
  l record;
  used numeric;
  hours numeric;
  rate numeric;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select * into m from public.usage_monthly where month = date_trunc('month', now())::date;
  for l in select * from public.usage_limits order by key loop
    if l.key = 'turn_bytes' then
      used := coalesce(m.turn_bytes, 0);
      hours := coalesce(m.turn_seconds, 0) / 3600.0;
    elsif l.key = 'proxy_requests' then
      used := coalesce(m.proxy_requests, 0);
      hours := coalesce(m.proxy_seconds, 0) / 3600.0;
    else
      continue;
    end if;
    rate := case when hours >= 1 and used > 0 then used / hours else l.default_rate end;
    result := result || jsonb_build_object(
      'key', l.key,
      'title', l.title,
      'used', used,
      'limit', l.monthly_limit,
      'hours_left', greatest(l.monthly_limit - used, 0) / rate);
  end loop;
  return jsonb_build_object(
    'month', date_trunc('month', now())::date,
    'resets', (date_trunc('month', now()) + interval '1 month')::date,
    'hours', coalesce(m.seconds, 0) / 3600.0,
    'limits', result);
end;
$$;

revoke all on function public.report_usage(int, int, int, bigint, int) from public, anon;
revoke all on function public.usage_summary() from public, anon;
grant execute on function public.report_usage(int, int, int, bigint, int) to authenticated;
grant execute on function public.usage_summary() to authenticated;
