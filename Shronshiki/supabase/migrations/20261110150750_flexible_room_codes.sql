alter table public.rooms drop constraint if exists rooms_code_check;
alter table public.rooms add constraint rooms_code_check check
 (char_length(code) between 1 and 64 and code = btrim(code) and code !~ '[[:cntrl:]]');
create or replace function public.find_room(p_code text)
returns table (id uuid, name text, code text, max_participants smallint, owner_name text)
language sql stable security definer set search_path = '' as $$
 select r.id,r.name,r.code,r.max_participants,p.display_name
 from public.rooms r left join public.profiles p on p.id=r.owner_id
 where auth.uid() is not null and (r.code=btrim(p_code) or
  (btrim(p_code) ~ '^[A-Za-z2-9]{6}$' and r.code=upper(btrim(p_code))))
 order by (r.code=btrim(p_code)) desc limit 1;
$$;
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
        update public.rooms set code = case when btrim(p_code) = '' then public.generate_room_code() else btrim(p_code) end where id = p_room;
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
