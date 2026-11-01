-- Shronshiki: начальная схема.
-- Выполнить в Supabase: SQL Editor -> New query -> вставить файл целиком -> Run.

-- ---------------------------------------------------------------------------
-- Профили пользователей
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 40),
  created_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles: read for signed-in" on public.profiles;
create policy "profiles: read for signed-in" on public.profiles
  for select to authenticated using (true);

drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Профиль создаётся автоматически при регистрации (и для гостей тоже).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), 'Гость'), 40)
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Комнаты
-- ---------------------------------------------------------------------------
create table if not exists public.rooms (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name             text not null check (char_length(name) between 1 and 60),
  -- 6 символов без похожих букв/цифр (нет I, O, 0, 1)
  code             text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  max_participants smallint not null default 4 check (max_participants between 2 and 4),
  created_at       timestamptz not null default now()
);

create index if not exists rooms_owner_idx on public.rooms (owner_id);

alter table public.rooms enable row level security;

-- Только владелец видит свои комнаты напрямую. Остальные находят комнату по коду через find_room().
drop policy if exists "rooms: owner select" on public.rooms;
create policy "rooms: owner select" on public.rooms
  for select to authenticated using (owner_id = (select auth.uid()));

-- Создавать комнаты могут только зарегистрированные (не анонимные) пользователи.
drop policy if exists "rooms: registered insert" on public.rooms;
create policy "rooms: registered insert" on public.rooms
  for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false
  );

drop policy if exists "rooms: owner update" on public.rooms;
create policy "rooms: owner update" on public.rooms
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

drop policy if exists "rooms: owner delete" on public.rooms;
create policy "rooms: owner delete" on public.rooms
  for delete to authenticated using (owner_id = (select auth.uid()));

-- Случайный код комнаты.
create or replace function public.generate_room_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  result text := '';
begin
  for i in 1..6 loop
    result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return result;
end;
$$;

-- Создание комнаты с уникальным кодом (RLS применяется, т.к. security invoker).
create or replace function public.create_room(p_name text)
returns public.rooms
language plpgsql
security invoker
set search_path = ''
as $$
declare
  new_room public.rooms;
begin
  for attempt in 1..10 loop
    begin
      insert into public.rooms (name, code)
      values (trim(p_name), public.generate_room_code())
      returning * into new_room;
      return new_room;
    exception when unique_violation then
      -- код совпал с существующим, пробуем другой
    end;
  end loop;
  raise exception 'Не удалось подобрать свободный код комнаты';
end;
$$;

-- Поиск комнаты по коду (доступен и гостям).
create or replace function public.find_room(p_code text)
returns table (id uuid, name text, code text, max_participants smallint, owner_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.name, r.code, r.max_participants, p.display_name
  from public.rooms r
  left join public.profiles p on p.id = r.owner_id
  where r.code = upper(trim(p_code))
  limit 1;
$$;

-- Проверка для политик Realtime: существует ли комната с таким топиком канала.
create or replace function public.is_room_topic(p_topic text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.rooms r where 'room:' || r.id::text = p_topic
  );
$$;

-- Явные права (в новых проектах Supabase таблицы могут не открываться API автоматически).
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.rooms to authenticated;
revoke all on public.profiles, public.rooms from anon;

revoke all on function public.create_room(text) from public, anon;
revoke all on function public.find_room(text) from public, anon;
revoke all on function public.is_room_topic(text) from public, anon;
revoke all on function public.generate_room_code() from public, anon;
grant execute on function public.create_room(text) to authenticated;
grant execute on function public.find_room(text) to authenticated;
grant execute on function public.is_room_topic(text) to authenticated;
grant execute on function public.generate_room_code() to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime: приватные каналы комнат (сигналинг WebRTC и список участников)
-- Канал называется room:<uuid комнаты>. Подключиться может любой вошедший
-- пользователь (в т.ч. гость), но только к существующей комнате.
-- ---------------------------------------------------------------------------
drop policy if exists "shronshiki: room channel read" on realtime.messages;
create policy "shronshiki: room channel read" on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension in ('broadcast', 'presence')
    and public.is_room_topic((select realtime.topic()))
  );

drop policy if exists "shronshiki: room channel write" on realtime.messages;
create policy "shronshiki: room channel write" on realtime.messages
  for insert to authenticated
  with check (
    realtime.messages.extension in ('broadcast', 'presence')
    and public.is_room_topic((select realtime.topic()))
  );
