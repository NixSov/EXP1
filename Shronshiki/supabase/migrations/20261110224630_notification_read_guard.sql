create or replace function public.claim_push_notice(p_id bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.message_notices; tokens jsonb;
begin
 update public.message_notices set push_leased_at=now() where id=p_id and push_sent_at is null and (push_leased_at is null or push_leased_at<now()-interval '2 minutes') returning * into n;
 if n.id is null then return null; end if;
 if exists(select 1 from public.chat_members where chat_id=n.chat_id and user_id=n.user_id and last_read_id>=n.chat_message) then update public.message_notices set push_sent_at=now() where id=n.id; return null; end if;
 if not (exists(select 1 from public.chat_members where chat_id=n.chat_id and user_id=n.user_id) or exists(select 1 from public.room_peers where room_id=n.room_id and user_id=n.user_id and last_seen>now()-interval '15 seconds')) then
  update public.message_notices set push_sent_at=now() where id=n.id; return null;
 end if;
 select coalesce(jsonb_agg(token),'[]') into tokens from public.push_devices where user_id=n.user_id and enabled and updated_at>now()-interval '90 days';
 return jsonb_build_object('id',n.id::text,'user',n.user_id,'chat_id',n.chat_id,'room_code',(select code from public.rooms where id=n.room_id),'tokens',tokens);
end $$;
