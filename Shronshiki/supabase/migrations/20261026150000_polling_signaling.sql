-- Shronshiki: сигналинг через короткие HTTP-запросы вместо Realtime (WebSocket).
-- Нужен, потому что часть провайдеров в России не пропускает WebSocket к Supabase.
-- Выполнить в Supabase: SQL Editor -> New query -> вставить файл целиком -> Run.

-- Кто сейчас в комнате. Запись живёт, пока участник опрашивает сервер.
create table if not exists public.room_peers (
  room_id   uuid not null references public.rooms (id) on delete cascade,
  peer_id   text not null check (char_length(peer_id) between 8 and 64),
  user_id   uuid not null references auth.users (id) on delete cascade,
  name      text not null,
  muted     boolean not null default false,
  joined_at bigint not null,
  last_seen timestamptz not null default now(),
  primary key (room_id, peer_id)
);

-- Служебные сообщения WebRTC (offer/answer/ICE) для конкретного участника.
create table if not exists public.room_signals (
  id         bigint generated always as identity primary key,
  room_id    uuid not null references public.rooms (id) on delete cascade,
  from_peer  text not null,
  to_peer    text not null,
  payload    jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists room_signals_inbox_idx on public.room_signals (room_id, to_peer, id);
create index if not exists room_signals_created_idx on public.room_signals (room_id, created_at);

-- Напрямую таблицы недоступны, только через функции ниже.
alter table public.room_peers enable row level security;
alter table public.room_signals enable row level security;
revoke all on public.room_peers, public.room_signals from anon, authenticated;

-- Опрос раз в 1–2 секунды: отметиться в комнате, получить участников и новые сообщения.
-- Если места нет — {"full": true}.
create or replace function public.room_poll(
  p_room uuid,
  p_peer text,
  p_name text,
  p_muted boolean,
  p_joined_at bigint,
  p_after bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  max_n int;
  live int;
  owner_id uuid;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select r.max_participants into max_n from public.rooms r where r.id = p_room;
  if max_n is null then
    raise exception 'room not found' using errcode = 'P0002';
  end if;

  -- Опросы одной комнаты выполняются по очереди: так нельзя вдвоём занять последнее место.
  perform pg_advisory_xact_lock(hashtextextended(p_room::text, 0));

  delete from public.room_peers
  where room_id = p_room and last_seen < now() - interval '15 seconds';
  delete from public.room_signals
  where room_id = p_room and created_at < now() - interval '2 minutes';

  select p.user_id into owner_id
  from public.room_peers p
  where p.room_id = p_room and p.peer_id = p_peer;

  if owner_id is null then
    select count(*) into live from public.room_peers where room_id = p_room;
    if live >= max_n then
      return jsonb_build_object('full', true);
    end if;
    insert into public.room_peers (room_id, peer_id, user_id, name, muted, joined_at)
    values (p_room, p_peer, uid, left(coalesce(p_name, 'Участник'), 40), coalesce(p_muted, false), p_joined_at);
  elsif owner_id <> uid then
    raise exception 'peer belongs to another user' using errcode = '42501';
  else
    update public.room_peers
    set name = left(coalesce(p_name, name), 40),
        muted = coalesce(p_muted, muted),
        last_seen = now()
    where room_id = p_room and peer_id = p_peer;
  end if;

  return jsonb_build_object(
    'full', false,
    'peers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'peer_id', p.peer_id, 'name', p.name, 'muted', p.muted, 'joined_at', p.joined_at)
             order by p.joined_at, p.peer_id)
      from public.room_peers p
      where p.room_id = p_room
    ), '[]'::jsonb),
    'signals', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'from', s.from_peer, 'payload', s.payload)
             order by s.id)
      from (
        select * from public.room_signals
        where room_id = p_room and to_peer = p_peer and id > coalesce(p_after, 0)
        order by id
        limit 200
      ) s
    ), '[]'::jsonb)
  );
end;
$$;

-- Отправка пачки сообщений: p_messages = [{"to": "...", "payload": {...}}, ...]
create or replace function public.room_send(p_room uuid, p_from text, p_messages jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.room_peers
    where room_id = p_room and peer_id = p_from and user_id = auth.uid()
  ) then
    raise exception 'not in room' using errcode = '42501';
  end if;
  if jsonb_typeof(p_messages) <> 'array' or jsonb_array_length(p_messages) > 100 then
    raise exception 'bad messages';
  end if;
  insert into public.room_signals (room_id, from_peer, to_peer, payload)
  select p_room, p_from, m ->> 'to', m -> 'payload'
  from jsonb_array_elements(p_messages) m
  where m ->> 'to' is not null and m -> 'payload' is not null;
end;
$$;

-- Выход из комнаты.
create or replace function public.room_leave(p_room uuid, p_peer text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.room_peers
  where room_id = p_room and peer_id = p_peer and user_id = auth.uid();
  delete from public.room_signals
  where room_id = p_room and to_peer = p_peer;
end;
$$;

revoke all on function public.room_poll(uuid, text, text, boolean, bigint, bigint) from public, anon;
revoke all on function public.room_send(uuid, text, jsonb) from public, anon;
revoke all on function public.room_leave(uuid, text) from public, anon;
grant execute on function public.room_poll(uuid, text, text, boolean, bigint, bigint) to authenticated;
grant execute on function public.room_send(uuid, text, jsonb) to authenticated;
grant execute on function public.room_leave(uuid, text) to authenticated;
