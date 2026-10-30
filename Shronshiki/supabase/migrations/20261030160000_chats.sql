-- Постоянные чаты по ключу: создатель получает 6-значный ключ, остальные входят
-- по нему и видят всю переписку. Сообщения не стираются. Работает через те же
-- короткие запросы, что и комнаты (chat_poll / chat_send), без WebSocket.

create table if not exists public.chats (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null check (char_length(name) between 1 and 60),
  owner_id   uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_members (
  chat_id      uuid not null references public.chats (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  joined_at    timestamptz not null default now(),
  last_read_id bigint not null default 0,
  primary key (chat_id, user_id)
);
create index if not exists chat_members_user_idx on public.chat_members (user_id);

create table if not exists public.chat_messages (
  id         bigint generated always as identity primary key,
  chat_id    uuid not null references public.chats (id) on delete cascade,
  user_id    uuid references auth.users (id) on delete set null,
  name       text not null,
  body       text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_chat_idx on public.chat_messages (chat_id, id);

alter table public.chats enable row level security;
alter table public.chat_members enable row level security;
alter table public.chat_messages enable row level security;
revoke all on public.chats, public.chat_members, public.chat_messages from anon, authenticated;

-- Чат как его видит участник.
create or replace function public.chat_info(p_chat uuid, p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', c.id, 'code', c.code, 'name', c.name,
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

create or replace function public.create_chat(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  new_id uuid;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'empty name';
  end if;
  loop
    begin
      insert into public.chats (code, name, owner_id)
      values (public.generate_room_code(), left(btrim(p_name), 60), uid)
      returning id into new_id;
      exit;
    exception when unique_violation then
      -- Такой ключ уже есть — пробуем другой.
    end;
  end loop;
  insert into public.chat_members (chat_id, user_id) values (new_id, uid);
  return public.chat_info(new_id, uid);
end;
$$;

-- Вход по ключу. null — такого чата нет.
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
  select id into found_id from public.chats where code = upper(btrim(p_code));
  if found_id is null then
    return null;
  end if;
  insert into public.chat_members (chat_id, user_id) values (found_id, uid)
  on conflict do nothing;
  return public.chat_info(found_id, uid);
end;
$$;

create or replace function public.my_chats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(public.chat_info(m.chat_id, auth.uid())
           order by coalesce((select max(id) from public.chat_messages x where x.chat_id = m.chat_id), 0) desc,
                    m.joined_at desc), '[]'::jsonb)
  from public.chat_members m
  where m.user_id = auth.uid();
$$;

-- Новые сообщения после p_after (при открытии — последние 100) или, с p_before,
-- 50 более старых для прокрутки вверх. Заодно отмечает прочитанное.
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
           'id', x.id, 'user_id', x.user_id, 'name', x.name, 'body', x.body,
           'at', (extract(epoch from x.created_at) * 1000)::bigint) order by x.id), '[]'::jsonb)
  into result
  from (
    select * from public.chat_messages msg
    where msg.chat_id = p_chat
      and (p_before is not null and msg.id < p_before
           or p_before is null and msg.id > coalesce(p_after, 0))
    order by msg.id desc
    limit case when p_before is not null then 50 else 100 end
  ) x;
  if p_before is null then
    update public.chat_members
    set last_read_id = greatest(last_read_id,
                                coalesce((select max(id) from public.chat_messages where chat_id = p_chat), 0))
    where chat_id = p_chat and user_id = uid;
  end if;
  return result;
end;
$$;

create or replace function public.chat_send(p_chat uuid, p_body text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  text_body text := btrim(coalesce(p_body, ''));
  author text;
  new_id bigint;
begin
  if not exists (select 1 from public.chat_members where chat_id = p_chat and user_id = uid) then
    raise exception 'not a member' using errcode = '42501';
  end if;
  if char_length(text_body) = 0 then
    raise exception 'empty message';
  end if;
  select display_name into author from public.profiles where id = uid;
  insert into public.chat_messages (chat_id, user_id, name, body)
  values (p_chat, uid, coalesce(author, 'Участник'), left(text_body, 2000))
  returning id into new_id;
  return new_id;
end;
$$;

-- Выйти из чата (переписка остаётся у остальных).
create or replace function public.leave_chat(p_chat uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.chat_members where chat_id = p_chat and user_id = auth.uid();
$$;

revoke all on function public.chat_info(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_chat(text) from public, anon;
revoke all on function public.join_chat(text) from public, anon;
revoke all on function public.my_chats() from public, anon;
revoke all on function public.chat_poll(uuid, bigint, bigint) from public, anon;
revoke all on function public.chat_send(uuid, text) from public, anon;
revoke all on function public.leave_chat(uuid) from public, anon;
grant execute on function public.create_chat(text) to authenticated;
grant execute on function public.join_chat(text) to authenticated;
grant execute on function public.my_chats() to authenticated;
grant execute on function public.chat_poll(uuid, bigint, bigint) to authenticated;
grant execute on function public.chat_send(uuid, text) to authenticated;
grant execute on function public.leave_chat(uuid) to authenticated;
