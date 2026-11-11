-- History is per account; room messages still disappear after the last peer leaves.
create table public.room_history (
 user_id uuid not null references auth.users(id) on delete cascade,
 room_id uuid not null references public.rooms(id) on delete cascade,
 visited_at timestamptz not null default now(), primary key(user_id,room_id)
);
create table public.chat_history (
 user_id uuid not null references auth.users(id) on delete cascade,
 chat_id uuid not null references public.chats(id) on delete cascade,
 visited_at timestamptz not null default now(), primary key(user_id,chat_id)
);
alter table public.room_history enable row level security;
alter table public.chat_history enable row level security;
revoke all on public.room_history, public.chat_history from public,anon,authenticated;
insert into public.chat_history(user_id,chat_id,visited_at) select user_id,chat_id,joined_at from public.chat_members on conflict do nothing;
insert into public.room_history(user_id,room_id) select user_id,room_id from public.room_peers on conflict do nothing;
insert into public.room_history(user_id,room_id,visited_at) select user_id,room_id,last_seen_at from public.room_members on conflict(user_id,room_id) do update set visited_at=greatest(public.room_history.visited_at,excluded.visited_at);
create function public.remember_membership() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='room_peers' then
  insert into public.room_history(user_id,room_id) values(new.user_id,new.room_id)
  on conflict(user_id,room_id) do update set visited_at=now();
 else
  insert into public.chat_history(user_id,chat_id) values(new.user_id,new.chat_id)
  on conflict(user_id,chat_id) do update set visited_at=now();
 end if;
 return new;
end $$;
revoke all on function public.remember_membership() from public,anon,authenticated;
create trigger remember_room after insert on public.room_peers for each row execute function public.remember_membership();
create trigger remember_chat after insert on public.chat_members for each row execute function public.remember_membership();
create function public.recent_rooms() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'code',r.code,'max_participants',r.max_participants) order by h.visited_at desc),'[]')
 from public.room_history h join public.rooms r on r.id=h.room_id where h.user_id=auth.uid();
$$;

alter table public.chats add column direct_a uuid references auth.users(id) on delete cascade;
alter table public.chats add column direct_b uuid references auth.users(id) on delete cascade;
alter table public.chats add constraint direct_pair_valid check ((direct_a is null and direct_b is null) or (direct_a is not null and direct_b is not null and direct_a<direct_b));
create unique index chats_direct_pair on public.chats(direct_a,direct_b) where direct_a is not null;
create function public.guard_direct_member() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.chats where id=new.chat_id and direct_a is not null and new.user_id not in (direct_a,direct_b)) then
  raise exception 'private dialog has exactly two participants' using errcode='42501';
 end if;
 return new;
end $$;
revoke all on function public.guard_direct_member() from public,anon,authenticated;
create trigger direct_members_only before insert or update on public.chat_members for each row execute function public.guard_direct_member();

create function public.chat_contacts() returns table(id uuid,name text) language sql stable security definer set search_path='' as $$
 select p.id,p.display_name from public.profiles p
 where p.id<>auth.uid() and auth.uid() is not null and (
 exists(select 1 from public.chat_members a join public.chat_members b on b.chat_id=a.chat_id where a.user_id=auth.uid() and b.user_id=p.id)
 or exists(select 1 from public.room_peers a join public.room_peers b on b.room_id=a.room_id where a.user_id=auth.uid() and b.user_id=p.id and a.last_seen>now()-interval '15 seconds' and b.last_seen>now()-interval '15 seconds')
 or exists(select 1 from public.room_members a join public.room_members b on b.room_id=a.room_id where a.user_id=auth.uid() and b.user_id=p.id)
 or exists(select 1 from public.chats c where (c.direct_a=auth.uid() and c.direct_b=p.id) or (c.direct_b=auth.uid() and c.direct_a=p.id))) order by p.display_name,p.id;
$$;
create function public.open_direct(p_user uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); cid uuid; a uuid; b uuid;
begin
 if uid is null or p_user=uid or not exists(select 1 from public.chat_contacts() x where x.id=p_user) then raise exception 'not an available contact' using errcode='42501'; end if;
 a:=least(uid,p_user); b:=greatest(uid,p_user);
 perform pg_advisory_xact_lock(hashtextextended(a::text||b::text,0));
 select id into cid from public.chats where direct_a=a and direct_b=b;
 if cid is null then
  insert into public.chats(code,name,owner_id,direct_a,direct_b) values(gen_random_uuid()::text,'Личный чат',uid,a,b) returning id into cid;
 end if;
 insert into public.chat_members(chat_id,user_id) values(cid,a),(cid,b) on conflict do nothing;
 return public.chat_info(cid,uid);
end $$;
create function public.direct_from_room(p_room uuid,p_peer text) returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid;
begin
 if not exists(select 1 from public.room_peers where room_id=p_room and user_id=auth.uid() and last_seen>now()-interval '15 seconds') then raise exception 'not in room' using errcode='42501'; end if;
 select user_id into target from public.room_peers where room_id=p_room and peer_id=p_peer and last_seen>now()-interval '15 seconds';
 return public.open_direct(target);
end $$;
create or replace function public.chat_info(p_chat uuid, p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', c.id, 'code', c.code, 'direct', c.direct_a is not null, 'is_member',true, 'name', case when c.direct_a is null then c.name else coalesce((select display_name from public.profiles where id=case when c.direct_a=p_user then c.direct_b else c.direct_a end),'Участник') end,
    'members', (select count(*) from public.chat_members x where x.chat_id = c.id),
    'unread', (select count(*) from public.chat_messages msg
               where msg.chat_id = c.id and msg.id > m.last_read_id
                 and msg.user_id is distinct from p_user),
    'last', (select jsonb_build_object('name', msg.name, 'body', left(msg.body, 120),
                                       'at', (extract(epoch from msg.created_at) * 1000)::bigint)
             from public.chat_messages msg where msg.chat_id = c.id order by msg.id desc limit 1))
  from public.chats c
  join public.chat_members m on m.chat_id = c.id and m.user_id = p_user
  where c.id = p_chat;
$$;

create or replace function public.join_chat(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  found_id uuid;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select id into found_id from public.chats where code = upper(btrim(p_code)) and direct_a is null;
  if found_id is null then
    return null;
  end if;
  insert into public.chat_members (chat_id, user_id) values (found_id, uid)
  on conflict do nothing;
  return public.chat_info(found_id, uid);
end;
$$;


create or replace function public.my_chats() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(
  case when m.user_id is not null then public.chat_info(c.id,auth.uid()) else jsonb_build_object('id',c.id,'name',case when c.direct_a is null then c.name else coalesce((select display_name from public.profiles where id=case when c.direct_a=auth.uid() then c.direct_b else c.direct_a end),'Участник') end,'code',c.code,'direct',c.direct_a is not null,'is_member',false,'members',0,'unread',0) end
  order by h.visited_at desc),'[]')
 from public.chat_history h join public.chats c on c.id=h.chat_id
 left join public.chat_members m on m.chat_id=c.id and m.user_id=auth.uid()
 where h.user_id=auth.uid();
$$;
create function public.rejoin_chat(p_chat uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.chat_history where user_id=auth.uid() and chat_id=p_chat) then raise exception 'not previously joined' using errcode='42501'; end if;
 insert into public.chat_members(chat_id,user_id) values(p_chat,auth.uid()) on conflict do nothing;
 return public.chat_info(p_chat,auth.uid());
end $$;
revoke all on function public.recent_rooms(), public.chat_contacts(), public.open_direct(uuid), public.direct_from_room(uuid,text), public.rejoin_chat(uuid) from public,anon;
grant execute on function public.recent_rooms(), public.chat_contacts(), public.open_direct(uuid), public.direct_from_room(uuid,text), public.rejoin_chat(uuid) to authenticated;

-- Durable, private inbox for notification delivery. Reading never marks chat messages read.
create table public.message_notices (
 id bigint generated always as identity primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 sender_id uuid references auth.users(id) on delete set null,
 chat_id uuid references public.chats(id) on delete cascade,
 room_id uuid references public.rooms(id) on delete cascade,
 chat_message bigint references public.chat_messages(id) on delete cascade,
 room_message bigint references public.room_messages(id) on delete cascade,
 created_at timestamptz not null default now(), push_sent_at timestamptz,
 check ((chat_message is null) <> (room_message is null))
);
create index message_notices_user_cursor on public.message_notices(user_id,id);
alter table public.message_notices enable row level security;
revoke all on public.message_notices from public,anon,authenticated;
create table public.push_devices (
 token text primary key check(char_length(token) between 32 and 4096),
 user_id uuid not null references auth.users(id) on delete cascade,
 enabled boolean not null default true, updated_at timestamptz not null default now()
);
create index push_devices_user on public.push_devices(user_id);
alter table public.push_devices enable row level security;
revoke all on public.push_devices from public,anon,authenticated;
create function public.register_push(p_token text,p_enabled boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'not authenticated' using errcode='42501'; end if;
 insert into public.push_devices(token,user_id,enabled) values(p_token,auth.uid(),p_enabled)
 on conflict(token) do update set user_id=auth.uid(),enabled=p_enabled,updated_at=now();
end $$;
create function public.message_notice_cursor() returns bigint language sql stable security definer set search_path='' as $$
 select coalesce(max(id),0) from public.message_notices where user_id=auth.uid();
$$;
create function public.message_notifications(p_after bigint default 0) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(x.data order by x.id),'[]') from (
  select n.id,jsonb_build_object('id',n.id,'chat_id',n.chat_id,'room_code',r.code,
   'title',coalesce(p.display_name,'Участник')||' написал(а) вам',
   'text',case when n.chat_id is not null then 'Новое сообщение в чате' else 'Новое сообщение в комнате' end) data
  from public.message_notices n left join public.rooms r on r.id=n.room_id left join public.profiles p on p.id=n.sender_id
  where n.user_id=auth.uid() and n.id>p_after and (
   exists(select 1 from public.chat_members c where c.chat_id=n.chat_id and c.user_id=auth.uid())
   or exists(select 1 from public.room_peers rp where rp.room_id=n.room_id and rp.user_id=auth.uid() and rp.last_seen>now()-interval '15 seconds'))
  order by n.id limit 100) x;
$$;
create function public.queue_message_notices() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='chat_messages' then
  insert into public.message_notices(user_id,sender_id,chat_id,chat_message)
  select user_id,new.user_id,new.chat_id,new.id from public.chat_members where chat_id=new.chat_id and user_id is distinct from new.user_id;
 else
  insert into public.message_notices(user_id,sender_id,room_id,room_message)
  select distinct user_id,new.user_id,new.room_id,new.id from public.room_peers
  where room_id=new.room_id and user_id is distinct from new.user_id and last_seen>now()-interval '15 seconds';
 end if;
 return new;
end $$;
revoke all on function public.queue_message_notices() from public,anon,authenticated;
create trigger chat_notice after insert on public.chat_messages for each row execute function public.queue_message_notices();
create trigger room_notice after insert on public.room_messages for each row execute function public.queue_message_notices();
revoke all on function public.register_push(text,boolean),public.message_notice_cursor(),public.message_notifications(bigint) from public,anon;
grant execute on function public.register_push(text,boolean),public.message_notice_cursor(),public.message_notifications(bigint) to authenticated;
