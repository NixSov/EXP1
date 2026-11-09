-- Apply after attachment helpers exist.
-- Fix authorization and cursor gaps; retain room chat cleanup.
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
               'id', m.id, 'peer_id', m.peer_id, 'name', m.name, 'body', m.body, 'attachment', public.message_file(m.id, true),
               'at', (extract(epoch from m.created_at) * 1000)::bigint)
             order by m.id)
      from (
        -- Новые сообщения; при входе (p_after_msg = 0) — последние 100.
        select * from (
          select * from public.room_messages
          where room_id = p_room and id > p_after_msg
          order by
            case when p_after_msg = 0 then id end desc,
            case when p_after_msg > 0 then id end asc
          limit 100
        ) last100
      ) m
    ), '[]'::jsonb) end
  );
end;
$$;

create or replace function public.room_leave(p_room uuid, p_peer text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_room::text, 0));
  if not exists (select 1 from public.room_peers
    where room_id = p_room and peer_id = p_peer and user_id = auth.uid()) then
    raise exception 'not your peer' using errcode = '42501';
  end if;
  delete from public.room_peers
  where room_id = p_room and peer_id = p_peer and user_id = auth.uid();
  delete from public.room_signals
  where room_id = p_room and to_peer = p_peer;
  if not exists (select 1 from public.room_peers where room_id = p_room) then
    delete from public.room_messages where room_id = p_room;
  end if;
end;
$$;

create or replace function public.chat_poll(p_chat uuid, p_after bigint default 0, p_before bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  result jsonb;
begin
  if not exists (select 1 from public.chat_members where chat_id = p_chat and user_id = uid) then
    raise exception 'not a member' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'user_id', x.user_id, 'name', x.name, 'body', x.body, 'attachment', public.message_file(x.id, false),
           'at', (extract(epoch from x.created_at) * 1000)::bigint) order by x.id), '[]'::jsonb)
  into result
  from (
    select * from public.chat_messages msg
    where msg.chat_id = p_chat
      and (p_before is not null and msg.id < p_before
           or p_before is null and msg.id > coalesce(p_after, 0))
    order by
      case when p_before is not null or coalesce(p_after, 0) = 0 then msg.id end desc,
      case when p_before is null and p_after > 0 then msg.id end asc
    limit case when p_before is not null then 50 else 100 end
  ) x;
  if p_before is null then
    update public.chat_members
    set last_read_id = greatest(last_read_id,
                                coalesce((select max((x ->> 'id')::bigint) from jsonb_array_elements(result) x), 0))
    where chat_id = p_chat and user_id = uid;
  end if;
  return result;
end;
$$;


-- Serialize chat writes with last-peer cleanup.
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
  perform pg_advisory_xact_lock(hashtextextended(p_room::text, 0));
  select * into me from public.room_peers
  where room_id = p_room and peer_id = p_peer and user_id = auth.uid()
    and last_seen > now() - interval '15 seconds';
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

