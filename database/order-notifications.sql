-- Transactional notifications only; historical orders are never backfilled.
create table private.website_notification_settings(id boolean primary key default true check(id),enabled boolean not null default false,updated_at timestamptz not null default now());
insert into private.website_notification_settings(id) values(true);
create table private.website_notification_optouts(phone text primary key,created_at timestamptz not null default now());
create table private.website_order_notifications(
 id uuid primary key default gen_random_uuid(),order_id uuid not null references private.website_orders(id),event text not null,
 phone text not null,payload jsonb not null,status text not null check(status in ('setup_required','queued','sending','accepted','sent','delivered','read','failed','unknown','skipped')),
 attempts integer not null default 0,next_attempt_at timestamptz not null default now(),lease_id uuid,claimed_at timestamptz,
 provider_id text unique,error_code text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(order_id,event)
);
alter table private.website_notification_settings enable row level security;
alter table private.website_notification_optouts enable row level security;
alter table private.website_order_notifications enable row level security;
revoke all on private.website_notification_settings,private.website_notification_optouts,private.website_order_notifications from public,anon,authenticated;
create index website_notification_queue_idx on private.website_order_notifications(next_attempt_at) where status='queued';
alter table private.website_orders add column whatsapp_updates_opt_in boolean not null default false;
alter table private.website_orders add column whatsapp_updates_opt_in_at timestamptz;
create function private.website_order_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare mobile text; details text; summary text; enabled boolean;
begin
 if tg_op='UPDATE' and old.status is not distinct from new.status then return new;end if;
 if not new.whatsapp_updates_opt_in then return new;end if;
 mobile:=regexp_replace(new.phone,'[^0-9]','','g');
 if mobile ~ '^03[0-9]{9}$' then mobile:='92'||substr(mobile,2);end if;
 if mobile ~ '^00' then mobile:=substr(mobile,3);end if;
 if mobile !~ '^[1-9][0-9]{9,14}$' then return new;end if;
 if exists(select 1 from private.website_notification_optouts where phone=mobile) then return new;end if;
 select s.enabled into enabled from private.website_notification_settings s where id;
 details:=case new.status when 'pending' then 'Request received. Stock and payment are not yet confirmed.' when 'confirmed' then case when new.fulfilment='pickup' then 'Confirmed and reserved. Contact the shop to arrange collection.' else 'Confirmed and reserved. We will notify you when dispatched. Delivery charges are confirmed separately.' end when 'dispatched' then 'Courier: '||coalesce(new.courier,'')||'. Tracking: '||coalesce(new.tracking_number,'') when 'completed' then case when new.fulfilment='pickup' then 'Collection completed. Thank you for shopping with AppleSpace.' else 'Delivery completed. Thank you for shopping with AppleSpace.' end when 'return_pending' then 'Delivery was not completed. Our team will contact you about the return.' when 'cancelled' then 'Order cancelled. Contact us about any payment or refund; this message does not confirm a refund.' else null end;
 if details is null then return new;end if;
 select left(string_agg((i->>'title')||' x '||(i->>'quantity'),'; '),400) into summary from jsonb_array_elements(new.items)i;
 -- Supersede unsent older status messages, so a delayed worker cannot send stale updates.
 update private.website_order_notifications set status='skipped',error_code='superseded',updated_at=now() where order_id=new.id and status in ('queued','setup_required');
 insert into private.website_order_notifications(order_id,event,phone,payload,status)
 values(new.id,new.status,mobile,jsonb_build_object('name',left(new.customer_name,80),'reference',upper(left(new.id::text,8)),'items',coalesce(summary,'Your order'),'amount','PKR '||new.total::text,'details',details),case when enabled then 'queued' else 'setup_required' end)
 on conflict(order_id,event) do nothing;
 return new;
end $$;
revoke all on function private.website_order_notice() from public,anon,authenticated;
create trigger website_order_notice after insert or update of status on private.website_orders for each row execute function private.website_order_notice();
do $patch$ declare src text;begin
 select pg_get_functiondef('private.website_checkout(jsonb)'::regprocedure) into src;
 src:=replace(src,'website_orders(customer_user_id,request_id','website_orders(whatsapp_updates_opt_in,whatsapp_updates_opt_in_at,customer_user_id,request_id');
 src:=replace(src,'values(auth.uid(),(p->>''request_id'')::uuid','values(coalesce(p->''whatsapp_updates_opt_in'',''false''::jsonb)=''true''::jsonb,case when p->''whatsapp_updates_opt_in''=''true''::jsonb then now() end,auth.uid(),(p->>''request_id'')::uuid');
 execute src;
end $patch$;
create function private.website_notifications_manage(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501';end if;
 if p->>'action'='settings' then
  if private.current_app_role() is distinct from 'owner'::public.app_role then raise exception 'Owner access required' using errcode='42501';end if;
  update private.website_notification_settings set enabled=coalesce((p->>'enabled')::boolean,false),updated_at=now() where id;
 end if;
 return jsonb_build_object('enabled',(select enabled from private.website_notification_settings where id),'messages',coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from (select id,order_id,event,status,attempts,error_code,created_at,updated_at,payload from private.website_order_notifications order by created_at desc limit 100)n),'[]'::jsonb));
end $$;
revoke all on function private.website_notifications_manage(jsonb) from public,anon;
grant execute on function private.website_notifications_manage(jsonb) to authenticated;
create function public.store_notifications(p jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select private.website_notifications_manage(p)$$;
revoke all on function public.store_notifications(jsonb) from public,anon;
grant execute on function public.store_notifications(jsonb) to authenticated;
-- Service-only worker API. No browser role can claim, acknowledge or spoof delivery.
create function private.website_notification_worker(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare a text:=p->>'action'; result jsonb; n private.website_order_notifications; incoming text; rank_old int; rank_new int;
begin
 if a='claim' then
  if not (select enabled from private.website_notification_settings where id) then return '[]';end if;
  update private.website_order_notifications set status='unknown',error_code='worker_interrupted_review_required',updated_at=now() where status='sending' and claimed_at<now()-interval '5 minutes';
  update private.website_order_notifications set status='skipped',error_code='expired_or_opted_out',updated_at=now() where status='queued' and (created_at<now()-interval '24 hours' or exists(select 1 from private.website_notification_optouts o where o.phone=website_order_notifications.phone));
  with picked as (select id from private.website_order_notifications where status='queued' and next_attempt_at<=now() and not exists(select 1 from private.website_order_notifications active where active.order_id=website_order_notifications.order_id and active.status='sending') order by created_at for update skip locked limit 3), claimed as (update private.website_order_notifications qn set status='sending',attempts=attempts+1,lease_id=gen_random_uuid(),claimed_at=now(),updated_at=now() from picked where qn.id=picked.id returning qn.*) select coalesce(jsonb_agg(to_jsonb(claimed)),'[]') into result from claimed;
  return result;
 elsif a='finish' then
  select * into n from private.website_order_notifications where id=(p->>'id')::uuid and lease_id=(p->>'lease_id')::uuid for update;
  if not found then return '{}';end if;
  if n.status in ('sent','delivered','read','failed') then return '{}';end if;
  incoming:=p->>'status';if incoming not in ('accepted','failed','unknown','queued') then raise exception 'Invalid outcome';end if;
  if incoming='queued' and n.attempts>=4 then incoming:='failed';end if;
  update private.website_order_notifications set status=incoming,provider_id=coalesce(nullif(p->>'provider_id',''),provider_id),error_code=left(p->>'error_code',150),next_attempt_at=now()+make_interval(secs=>least(3600,60*power(2,n.attempts)::int)),updated_at=now() where id=n.id;
 elsif a='delivery' then
  select * into n from private.website_order_notifications where (provider_id=p->>'provider_id' or id::text=p->>'correlation') and phone=p->>'phone' for update;
  if not found then return '{}';end if;
  incoming:=p->>'status';if incoming not in ('sent','delivered','read','failed') then return '{}';end if;
  rank_old:=case n.status when 'read' then 5 when 'delivered' then 4 when 'failed' then 3 when 'sent' then 2 else 0 end;
  rank_new:=case incoming when 'read' then 5 when 'delivered' then 4 when 'failed' then 3 when 'sent' then 2 else 0 end;
  if rank_new<=rank_old then return '{}';end if;
  update private.website_order_notifications set status=incoming,provider_id=p->>'provider_id',error_code=left(p->>'error_code',150),updated_at=now() where id=n.id;
 elsif a='stop' then
  if p->>'phone' !~ '^[1-9][0-9]{9,14}$' then return '{}';end if;
  insert into private.website_notification_optouts(phone) values(p->>'phone') on conflict do nothing;
  update private.website_order_notifications set status='skipped',error_code='customer_opted_out',updated_at=now() where phone=p->>'phone' and status in ('queued','setup_required');
 else raise exception 'Unknown worker action';end if;
 return '{}';
end $$;
revoke all on function private.website_notification_worker(jsonb) from public,anon,authenticated;
grant execute on function private.website_notification_worker(jsonb) to service_role;
create function public.store_notification_worker(p jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.website_notification_worker(p)$$;
revoke all on function public.store_notification_worker(jsonb) from public,anon,authenticated;
grant execute on function public.store_notification_worker(jsonb) to service_role;

grant usage on schema private to service_role;
