-- Private attachments; rows are deleted together with their message.
create table if not exists public.message_files (
 id uuid primary key default gen_random_uuid(),
 chat_message bigint references public.chat_messages(id) on delete cascade,
 room_message bigint references public.room_messages(id) on delete cascade,
 filename text not null check (char_length(filename) between 1 and 255),
 mime text not null,
 data bytea not null check (octet_length(data) between 1 and 2097152),
 check ((chat_message is null) <> (room_message is null))
);
create unique index if not exists message_files_chat_idx on public.message_files(chat_message);
create unique index if not exists message_files_room_idx on public.message_files(room_message);
alter table public.message_files enable row level security;
revoke all on public.message_files from anon, authenticated;

create or replace function public.send_file(p_target uuid, p_room boolean, p_peer text,
 p_filename text, p_mime text, p_data text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare mid bigint; bytes bytea;
begin
 if p_filename is null or btrim(p_filename) = '' or p_filename ~ '[/\\[:cntrl:]]' then
   raise exception 'invalid filename';
 end if;
 if char_length(p_data) > 2796204 then raise exception 'file too large'; end if;
 bytes := decode(p_data, 'base64');
 if p_room then
   perform pg_advisory_xact_lock(hashtextextended(p_target::text, 0));
   -- Existing RPC performs authorization, validation and mention processing.
   mid := public.room_chat_send(p_target, p_peer, left(p_filename, 255));
   insert into public.message_files(room_message, filename, mime, data)
   values(mid, left(p_filename,255), left(p_mime,100), bytes);
 else
   mid := public.chat_send(p_target, left(p_filename,255));
   insert into public.message_files(chat_message, filename, mime, data)
   values(mid, left(p_filename,255), left(p_mime,100), bytes);
 end if;
 return mid;
end; $$;

create or replace function public.message_file(p_message bigint, p_room boolean, p_content boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare f public.message_files;
begin
 if p_room then
   if not exists(select 1 from public.room_messages m join public.room_peers r on r.room_id=m.room_id
     where m.id=p_message and r.user_id=auth.uid() and r.last_seen > now()-interval '15 seconds')
   then raise exception 'not a member' using errcode='42501'; end if;
   select * into f from public.message_files where room_message=p_message;
 else
   if not exists(select 1 from public.chat_messages m join public.chat_members c on c.chat_id=m.chat_id
     where m.id=p_message and c.user_id=auth.uid())
   then raise exception 'not a member' using errcode='42501'; end if;
   select * into f from public.message_files where chat_message=p_message;
 end if;
 if f.id is null then return null; end if;
 return jsonb_build_object('name',f.filename,'mime',f.mime,'size',octet_length(f.data),
   'data',case when p_content then encode(f.data,'base64') else null end);
end; $$;
revoke all on function public.send_file(uuid, boolean, text, text, text, text) from public, anon;
revoke all on function public.message_file(bigint, boolean, boolean) from public, anon;
grant execute on function public.send_file(uuid, boolean, text, text, text, text) to authenticated;
grant execute on function public.message_file(bigint, boolean, boolean) to authenticated;
