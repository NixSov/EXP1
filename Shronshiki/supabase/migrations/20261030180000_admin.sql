-- Админ-панель: всё видно и всё можно менять только администраторам (таблица
-- app_admins из миграции chats). Каждая функция сама проверяет права, поэтому
-- без них ничего не сработает, даже из переделанного приложения.
-- Пароли и удаление аккаунтов — прямо в auth.users, без ключа службы в приложении.

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.app_admins where user_id = auth.uid());
$$;

create or replace function public.admin_guard()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admins only' using errcode = '42501';
  end if;
end;
$$;

-- Код вручную (6 символов из алфавита кодов) или новый случайный (p_code пустой).
create or replace function public.admin_pick_code(p_code text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c text := upper(btrim(coalesce(p_code, '')));
begin
  if c = '' then
    return public.generate_room_code();
  end if;
  if c !~ '^[A-HJ-NP-Z2-9]{6}$' then
    raise exception 'код — 6 символов: латинские буквы без I и O, цифры 2–9';
  end if;
  return c;
end;
$$;

-- ---------------------------------------------------------------------------
-- Комнаты
-- ---------------------------------------------------------------------------

create or replace function public.admin_rooms()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'name', r.name, 'code', r.code,
             'owner', p.display_name, 'owner_email', u.email,
             'created', (extract(epoch from r.created_at) * 1000)::bigint,
             'online', (select count(*) from public.room_peers x
                        where x.room_id = r.id and x.last_seen > now() - interval '15 seconds'))
           order by r.created_at desc)
    from public.rooms r
    left join public.profiles p on p.id = r.owner_id
    left join auth.users u on u.id = r.owner_id
  ), '[]'::jsonb);
end;
$$;

-- p_name / p_code: null — не менять; p_code = '' — новый случайный код.
create or replace function public.admin_room_update(p_room uuid, p_name text default null, p_code text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  if p_name is not null then
    update public.rooms set name = left(btrim(p_name), 60) where id = p_room;
  end if;
  if p_code is not null then
    loop
      begin
        update public.rooms set code = public.admin_pick_code(p_code) where id = p_room;
        exit;
      exception when unique_violation then
        if btrim(p_code) <> '' then
          raise exception 'такой код уже занят';
        end if;
      end;
    end loop;
  end if;
end;
$$;

create or replace function public.admin_room_delete(p_room uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  delete from public.rooms where id = p_room;
end;
$$;

-- ---------------------------------------------------------------------------
-- Чаты
-- ---------------------------------------------------------------------------

create or replace function public.admin_chats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'name', c.name, 'code', c.code,
             'owner', p.display_name,
             'members', (select count(*) from public.chat_members m where m.chat_id = c.id),
             'messages', (select count(*) from public.chat_messages x where x.chat_id = c.id),
             'created', (extract(epoch from c.created_at) * 1000)::bigint)
           order by c.created_at desc)
    from public.chats c
    left join public.profiles p on p.id = c.owner_id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_chat_update(p_chat uuid, p_name text default null, p_code text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  if p_name is not null then
    update public.chats set name = left(btrim(p_name), 60) where id = p_chat;
  end if;
  if p_code is not null then
    loop
      begin
        update public.chats set code = public.admin_pick_code(p_code) where id = p_chat;
        exit;
      exception when unique_violation then
        if btrim(p_code) <> '' then
          raise exception 'такой ключ уже занят';
        end if;
      end;
    end loop;
  end if;
end;
$$;

create or replace function public.admin_chat_delete(p_chat uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  delete from public.chats where id = p_chat;
end;
$$;

-- Переписка любого чата: последние 100 или, с p_before, 50 более старых.
create or replace function public.admin_chat_messages(p_chat uuid, p_before bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', x.id, 'user_id', x.user_id, 'name', x.name, 'body', x.body,
             'at', (extract(epoch from x.created_at) * 1000)::bigint) order by x.id)
    from (
      select * from public.chat_messages
      where chat_id = p_chat and (p_before is null or id < p_before)
      order by id desc
      limit case when p_before is null then 100 else 50 end
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_chat_message_delete(p_message bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  delete from public.chat_messages where id = p_message;
end;
$$;

-- ---------------------------------------------------------------------------
-- Аккаунты
-- ---------------------------------------------------------------------------

-- p_guests: true — только гости, false — только зарегистрированные.
create or replace function public.admin_users(p_guests boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', u.id, 'name', coalesce(p.display_name, 'Без имени'), 'email', u.email,
             'created', (extract(epoch from u.created_at) * 1000)::bigint,
             'last_sign_in', (extract(epoch from u.last_sign_in_at) * 1000)::bigint,
             'guest', coalesce(u.is_anonymous, false),
             'admin', exists (select 1 from public.app_admins a where a.user_id = u.id),
             'rooms', (select count(*) from public.rooms r where r.owner_id = u.id))
           order by coalesce(u.last_sign_in_at, u.created_at) desc)
    from auth.users u
    left join public.profiles p on p.id = u.id
    where coalesce(u.is_anonymous, false) = p_guests
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_user_rename(p_user uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  n text := left(btrim(coalesce(p_name, '')), 40);
begin
  perform public.admin_guard();
  if n = '' then
    raise exception 'пустое имя';
  end if;
  update public.profiles set display_name = n where id = p_user;
  -- Имя хранится и в метаданных аккаунта — приложение показывает его оттуда.
  update auth.users
  set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('display_name', n)
  where id = p_user;
end;
$$;

create or replace function public.admin_user_set_password(p_user uuid, p_password text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  if char_length(coalesce(p_password, '')) < 6 then
    raise exception 'пароль — не меньше 6 символов';
  end if;
  update auth.users
  set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
      updated_at = now()
  where id = p_user and coalesce(is_anonymous, false) = false;
  if not found then
    raise exception 'аккаунт не найден или это гость';
  end if;
end;
$$;

-- Удаление аккаунта: его комнаты и чаты переходят администратору, сообщения в
-- чатах остаются с подписью «Удалённый пользователь».
create or replace function public.admin_user_delete(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  perform public.admin_guard();
  if p_user = me then
    raise exception 'нельзя удалить свой аккаунт';
  end if;
  update public.rooms set owner_id = me where owner_id = p_user;
  update public.chats set owner_id = me where owner_id = p_user;
  update public.chat_messages set name = 'Удалённый пользователь' where user_id = p_user;
  delete from auth.users where id = p_user;
end;
$$;

create or replace function public.admin_set_admin(p_user uuid, p_admin boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.admin_guard();
  if p_user = auth.uid() and not p_admin then
    raise exception 'нельзя забрать права у себя';
  end if;
  if p_admin then
    insert into public.app_admins (user_id)
    select id from auth.users where id = p_user and coalesce(is_anonymous, false) = false
    on conflict do nothing;
  else
    delete from public.app_admins where user_id = p_user;
  end if;
end;
$$;

-- Удалить гостей, которые не заходили дольше p_days дней. Возвращает, сколько удалено.
create or replace function public.admin_delete_old_guests(p_days int default 30)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  n int;
begin
  perform public.admin_guard();
  update public.chat_messages m set name = 'Удалённый пользователь'
  from auth.users u
  where m.user_id = u.id and coalesce(u.is_anonymous, false)
    and coalesce(u.last_sign_in_at, u.created_at) < now() - make_interval(days => greatest(p_days, 1));
  update public.rooms r set owner_id = me
  from auth.users u
  where r.owner_id = u.id and coalesce(u.is_anonymous, false)
    and coalesce(u.last_sign_in_at, u.created_at) < now() - make_interval(days => greatest(p_days, 1));
  delete from auth.users
  where coalesce(is_anonymous, false)
    and coalesce(last_sign_in_at, created_at) < now() - make_interval(days => greatest(p_days, 1));
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Права: всё — только вошедшим (проверка администратора внутри каждой функции).
revoke all on function public.admin_guard() from public, anon, authenticated;
revoke all on function public.admin_pick_code(text) from public, anon, authenticated;
do $$
declare
  f text;
begin
  foreach f in array array[
    'is_admin()', 'admin_rooms()', 'admin_room_update(uuid, text, text)', 'admin_room_delete(uuid)',
    'admin_chats()', 'admin_chat_update(uuid, text, text)', 'admin_chat_delete(uuid)',
    'admin_chat_messages(uuid, bigint)', 'admin_chat_message_delete(bigint)',
    'admin_users(boolean)', 'admin_user_rename(uuid, text)', 'admin_user_set_password(uuid, text)',
    'admin_user_delete(uuid)', 'admin_set_admin(uuid, boolean)', 'admin_delete_old_guests(int)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;
