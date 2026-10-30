-- TURN-серверы на сервере: приложение и сайт получают их после входа (в том числе
-- гости), поэтому вписывать TURN на каждом телефоне не нужно, а в коде сайта
-- логина и пароля нет. Серверов может быть несколько — WebRTC выберет рабочий.
--
-- Добавить сервер (выполнить в SQL Editor, подставив свои данные):
--   insert into public.ice_servers (name, urls, username, credential) values (
--     'ExpressTURN',
--     'turn:free.expressturn.com:3478?transport=udp,turn:free.expressturn.com:3478?transport=tcp',
--     'ИМЯ_ПОЛЬЗОВАТЕЛЯ', 'ПАРОЛЬ');
-- Выключить: update public.ice_servers set enabled = false where name = 'ExpressTURN';

create table if not exists public.ice_servers (
  id         bigint generated always as identity primary key,
  name       text not null,
  urls       text not null,
  username   text not null default '',
  credential text not null default '',
  priority   int not null default 100,
  enabled    boolean not null default true
);

alter table public.ice_servers enable row level security;
revoke all on public.ice_servers from anon, authenticated;

create or replace function public.get_ice_servers()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'name', s.name,
             'urls', (select coalesce(jsonb_agg(btrim(u)), '[]'::jsonb)
                      from unnest(regexp_split_to_array(s.urls, '[,\s]+')) as u
                      where btrim(u) <> ''),
             'username', s.username,
             'credential', s.credential)
           order by s.priority, s.id)
    from public.ice_servers s
    where s.enabled
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.get_ice_servers() from public, anon;
grant execute on function public.get_ice_servers() to authenticated;
