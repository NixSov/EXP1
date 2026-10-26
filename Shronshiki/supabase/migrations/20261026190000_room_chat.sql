-- Shronshiki: мини-чат комнаты.
-- Сообщения видят только участники комнаты. Когда из комнаты выходят все
-- (явно или пропав больше чем на 15 секунд), переписка удаляется.
-- Выполнить в Supabase: SQL Editor -> New query -> вставить файл целиком -> Run.

create table if not exists public.room_messages (
  id         bigint generated always as identity primary key,
  room_id    uuid not null references public.rooms (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  peer_id    text not null,
  name       text not null,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);

create index if not exists room_messages_room_idx on public.room_messages (room_id, id);

alter table public.room_messages enable row level security;
revoke all on public.room_messages from anon, authenticated;

-- Опрос теперь возвращает и новые сообщения чата (p_after_msg).
-- Старые версии приложения вызывают функцию без этого параметра — для них чат не приходит.
drop function if exists public.room_poll(uuid, text, text, boolean, bigint, bigint);

create or replace function public.room_poll(
  p_room uuid,
  p_peer text,
  p_name text,
  p_muted boolean,
  p_joined_at bigint,
  p_after bigint,
  p_after_msg bigint default null
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

  perform pg_advisory_xact_lock(hashtextextended(p_room::text, 0));

  delete from public.room_peers
  where room_id = p_room and last_seen < now() - interval '15 seconds';
  delete from public.room_signals
  where room_id = p_room and created_at < now() - interval '2 minutes';

  -- В комнате никого не осталось — переписка прошлой встречи удаляется.
  if not exists (select 1 from public.room_peers where room_id = p_room) then
    delete from public.room_messages where room_id = p_room;
  end if;

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
    ), '[]'::jsonb),
    'messages', case when p_after_msg is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'peer_id', m.peer_id, 'name', m.name, 'body', m.body,
               'at', (extract(epoch from m.created_at) * 1000)::bigint)
             order by m.id)
      from (
        -- Новые сообщения; при входе (p_after_msg = 0) — последние 100.
        select * from (
          select * from public.room_messages
          where room_id = p_room and id > p_after_msg
          order by id desc
          limit 100
        ) last100
      ) m
    ), '[]'::jsonb) end
  );
end;
$$;

-- Отправка сообщения в чат (только участник комнаты).
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
  return new_id;
end;
$$;

-- Выход: если ушёл последний — чат очищается сразу.
create or replace function public.room_leave(p_room uuid, p_peer text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_room::text, 0));
  delete from public.room_peers
  where room_id = p_room and peer_id = p_peer and user_id = auth.uid();
  delete from public.room_signals
  where room_id = p_room and to_peer = p_peer;
  if not exists (select 1 from public.room_peers where room_id = p_room) then
    delete from public.room_messages where room_id = p_room;
  end if;
end;
$$;

revoke all on function public.room_poll(uuid, text, text, boolean, bigint, bigint, bigint) from public, anon;
revoke all on function public.room_chat_send(uuid, text, text) from public, anon;
revoke all on function public.room_leave(uuid, text) from public, anon;
grant execute on function public.room_poll(uuid, text, text, boolean, bigint, bigint, bigint) to authenticated;
grant execute on function public.room_chat_send(uuid, text, text) to authenticated;
grant execute on function public.room_leave(uuid, text) to authenticated;
