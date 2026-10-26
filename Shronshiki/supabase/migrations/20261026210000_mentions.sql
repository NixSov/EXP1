-- Shronshiki: упоминания в чате (@Имя) -> уведомление на устройство или письмо.
-- Выполнить в Supabase: SQL Editor -> New query -> вставить файл целиком -> Run.
-- В конце запрос покажет NOTIFY_SECRET — его нужно вписать в посредника (Deno)
-- и в скрипт отправки писем (Google Apps Script).

-- Кто бывал в комнате: этих людей можно упомянуть, даже когда их сейчас нет.
create table if not exists public.room_members (
  room_id      uuid not null references public.rooms (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  name         text not null,
  last_seen_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

-- Уведомления об упоминаниях.
create table if not exists public.notifications (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users (id) on delete cascade,
  room_id      uuid not null references public.rooms (id) on delete cascade,
  from_user    uuid references auth.users (id) on delete set null,
  from_name    text not null,
  body         text not null,
  created_at   timestamptz not null default now(),
  delivered_at timestamptz, -- показано в приложении
  emailed_at   timestamptz  -- отправлено письмом
);
create index if not exists notifications_user_idx on public.notifications (user_id, id);
create index if not exists notifications_pending_idx on public.notifications (created_at)
  where delivered_at is null and emailed_at is null;

-- Общий секрет для отправки писем (знают только база, посредник и скрипт писем).
create table if not exists public.notify_secret (
  id    boolean primary key default true check (id),
  value text not null
);
insert into public.notify_secret (value)
values (encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (id) do nothing;

alter table public.room_members enable row level security;
alter table public.notifications enable row level security;
alter table public.notify_secret enable row level security;
revoke all on public.room_members, public.notifications, public.notify_secret from anon, authenticated;

-- Присылать ли упоминания на почту (настройка в приложении).
alter table public.profiles add column if not exists email_mentions boolean not null default true;

-- Каждый вход в комнату записывает человека в её участники.
create or replace function public.remember_room_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.room_members (room_id, user_id, name, last_seen_at)
  values (new.room_id, new.user_id, new.name, now())
  on conflict (room_id, user_id) do update set name = excluded.name, last_seen_at = now();
  return new;
end;
$$;

drop trigger if exists on_room_peer_joined on public.room_peers;
create trigger on_room_peer_joined
  after insert on public.room_peers
  for each row execute function public.remember_room_member();

-- Отправка в чат + уведомления упомянутым, кого сейчас нет в комнате.
-- @Имя — один человек, @все / @all — все участники комнаты.
create or replace function public.room_chat_send(p_room uuid, p_peer text, p_body text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  me public.room_peers;
  new_id bigint;
  text_body text := btrim(coalesce(p_body, ''));
  everyone boolean;
begin
  select * into me from public.room_peers
  where room_id = p_room and peer_id = p_peer and user_id = auth.uid();
  if not found then
    raise exception 'not in room' using errcode = '42501';
  end if;
  if char_length(text_body) = 0 then
    raise exception 'empty message';
  end if;
  insert into public.room_messages (room_id, user_id, peer_id, name, body)
  values (p_room, me.user_id, p_peer, me.name, left(text_body, 1000))
  returning id into new_id;

  if position('@' in text_body) > 0 then
    everyone := text_body ~* '(^|[^[:alnum:]_])@(все|all)($|[^[:alnum:]_])';
    insert into public.notifications (user_id, room_id, from_user, from_name, body)
    select m.user_id, p_room, me.user_id, me.name, left(text_body, 500)
    from public.room_members m
    where m.room_id = p_room
      and m.user_id <> me.user_id
      and not exists (
        select 1 from public.room_peers p where p.room_id = p_room and p.user_id = m.user_id
      )
      and (
        everyone
        or text_body ~* ('(^|[^[:alnum:]_])@'
          || regexp_replace(m.name, '([][\\.^$*+?(){}|-])', '\\\1', 'g')
          || '($|[^[:alnum:]_])')
      )
    limit 20;
  end if;
  return new_id;
end;
$$;

-- Кого можно упомянуть в комнате (для подсказки при вводе «@»).
create or replace function public.room_member_names(p_room uuid)
returns table (name text, in_room boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select m.name,
         exists (select 1 from public.room_peers p where p.room_id = m.room_id and p.user_id = m.user_id)
  from public.room_members m
  where m.room_id = p_room
    and exists (select 1 from public.room_peers me where me.room_id = p_room and me.user_id = auth.uid())
  order by m.last_seen_at desc
  limit 50;
$$;

-- Новые уведомления для меня (приложение спрашивает раз в ~30 секунд).
-- Выданное приложению уже не уйдёт письмом.
create or replace function public.my_notifications()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  result jsonb;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  delete from public.notifications where user_id = uid and created_at < now() - interval '7 days';
  with fresh as (
    update public.notifications n
    set delivered_at = now()
    where n.user_id = uid
      and n.delivered_at is null
      and n.emailed_at is null
      and n.created_at > now() - interval '1 day'
    returning n.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', f.id, 'from_name', f.from_name, 'body', f.body,
           'room_name', r.name, 'room_code', r.code,
           'at', (extract(epoch from f.created_at) * 1000)::bigint)
         order by f.id), '[]'::jsonb)
  into result
  from fresh f
  join public.rooms r on r.id = f.room_id;
  return result;
end;
$$;

-- Для посредника: упоминания, которые никто не забрал в приложении за 90 секунд,
-- уходят письмом. Защищено общим секретом.
create or replace function public.claim_mention_emails(p_secret text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if p_secret is null or p_secret <> (select value from public.notify_secret) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  with picked as (
    select n.id
    from public.notifications n
    join auth.users u on u.id = n.user_id
    left join public.profiles pr on pr.id = n.user_id
    where n.delivered_at is null
      and n.emailed_at is null
      and n.created_at < now() - interval '90 seconds'
      and n.created_at > now() - interval '1 day'
      and u.email is not null
      and coalesce(u.is_anonymous, false) = false
      and coalesce(pr.email_mentions, true)
    order by n.id
    limit 50
    for update of n skip locked
  ),
  sent as (
    update public.notifications n
    set emailed_at = now()
    from picked
    where n.id = picked.id
    returning n.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'email', u.email, 'from_name', s.from_name, 'body', s.body,
           'room_name', r.name, 'room_code', r.code)
         order by s.id), '[]'::jsonb)
  into result
  from sent s
  join auth.users u on u.id = s.user_id
  join public.rooms r on r.id = s.room_id;
  return result;
end;
$$;

-- Настройка «присылать на почту».
create or replace function public.set_email_mentions(p_enabled boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.profiles set email_mentions = p_enabled where id = auth.uid();
$$;

create or replace function public.get_email_mentions()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select email_mentions from public.profiles where id = auth.uid()), true);
$$;

revoke all on function public.remember_room_member() from public, anon, authenticated;
revoke all on function public.room_chat_send(uuid, text, text) from public, anon;
revoke all on function public.room_member_names(uuid) from public, anon;
revoke all on function public.my_notifications() from public, anon;
revoke all on function public.claim_mention_emails(text) from public;
revoke all on function public.set_email_mentions(boolean) from public, anon;
revoke all on function public.get_email_mentions() from public, anon;
grant execute on function public.room_chat_send(uuid, text, text) to authenticated;
grant execute on function public.room_member_names(uuid) to authenticated;
grant execute on function public.my_notifications() to authenticated;
grant execute on function public.claim_mention_emails(text) to anon, authenticated;
grant execute on function public.set_email_mentions(boolean) to authenticated;
grant execute on function public.get_email_mentions() to authenticated;

-- Секрет для посредника и скрипта писем.
select value as "NOTIFY_SECRET" from public.notify_secret;
