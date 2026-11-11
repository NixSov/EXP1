-- Server-only push delivery. No private keys are stored in source or APKs.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
alter table public.message_notices add column push_leased_at timestamptz;
create function public.push_runtime_config() returns jsonb language plpgsql security definer set search_path='' as $$
declare config jsonb;
begin
 execute $q$select jsonb_object_agg(name,decrypted_secret) from vault.decrypted_secrets where name in ('message_push_secret','fcm_service_account','message_push_url')$q$ into config;
 return config;
end $$;
create function public.claim_push_notice(p_id bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.message_notices; tokens jsonb;
begin
 update public.message_notices set push_leased_at=now() where id=p_id and push_sent_at is null and (push_leased_at is null or push_leased_at<now()-interval '2 minutes') returning * into n;
 if n.id is null then return null; end if;
 if not (exists(select 1 from public.chat_members where chat_id=n.chat_id and user_id=n.user_id) or exists(select 1 from public.room_peers where room_id=n.room_id and user_id=n.user_id and last_seen>now()-interval '15 seconds')) then
  update public.message_notices set push_sent_at=now() where id=n.id; return null;
 end if;
 select coalesce(jsonb_agg(token),'[]') into tokens from public.push_devices where user_id=n.user_id and enabled and updated_at>now()-interval '90 days';
 return jsonb_build_object('id',n.id::text,'user',n.user_id,'chat_id',n.chat_id,'room_code',(select code from public.rooms where id=n.room_id),'tokens',tokens);
end $$;
create function public.finish_push_notice(p_id bigint,p_success boolean,p_invalid text[] default '{}') returns void language plpgsql security definer set search_path='' as $$
begin
 update public.push_devices set enabled=false where token=any(p_invalid);
 update public.message_notices set push_sent_at=case when p_success then now() else null end,push_leased_at=null where id=p_id;
end $$;
create function public.send_pending_push(p_id bigint default null) returns void language plpgsql security definer set search_path='' as $$
declare config jsonb; n record;
begin
 config:=public.push_runtime_config();
 if config->>'message_push_url' is null or config->>'message_push_secret' is null or config->>'fcm_service_account' is null then return; end if;
 for n in select id from public.message_notices m where (p_id is null or id=p_id) and push_sent_at is null
   and (push_leased_at is null or push_leased_at<now()-interval '2 minutes') and created_at>now()-interval '1 day'
   and exists(select 1 from public.push_devices d where d.user_id=m.user_id and d.enabled and d.updated_at>now()-interval '90 days') order by id limit 50 loop
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 10000)'
   using config->>'message_push_url',jsonb_build_object('Content-Type','application/json','x-push-secret',config->>'message_push_secret'),jsonb_build_object('id',n.id::text);
 end loop;
exception when others then
 -- Notification outages must never prevent messages from being sent.
 raise log 'push enqueue failed, queued notices retained';
end $$;
create function public.wake_message_push() returns trigger language plpgsql security definer set search_path='' as $$
begin perform public.send_pending_push(new.id); return new; end $$;
create trigger dispatch_message_push after insert on public.message_notices for each row execute function public.wake_message_push();
revoke all on function public.push_runtime_config(),public.claim_push_notice(bigint),public.finish_push_notice(bigint,boolean,text[]),public.send_pending_push(bigint),public.wake_message_push() from public,anon,authenticated;
grant execute on function public.push_runtime_config(),public.claim_push_notice(bigint),public.finish_push_notice(bigint,boolean,text[]) to service_role;
select cron.schedule('shronshiki-message-push-retry','* * * * *','select public.send_pending_push()');
