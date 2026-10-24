begin;
do $$ declare o uuid:=gen_random_uuid(); no_consent uuid:=gen_random_uuid(); d jsonb; n uuid; lease uuid;begin
 insert into private.website_orders(id,request_id,customer_name,phone,fulfilment,address,notes,total,items,whatsapp_updates_opt_in,whatsapp_updates_opt_in_at)
 values(o,gen_random_uuid(),'Notification verification','03000000000','pickup','','',1000,'[{"title":"Test phone","quantity":1}]',true,now());
 if not exists(select 1 from private.website_order_notifications where order_id=o and status='setup_required' and phone='923000000000') then raise exception 'Disabled setup/normalization failed';end if;
 update private.website_orders set notes='No status change' where id=o;
 if (select count(*) from private.website_order_notifications where order_id=o)<>1 then raise exception 'Duplicate event';end if;
 insert into private.website_orders(id,request_id,customer_name,phone,fulfilment,address,notes,total,items)
 values(no_consent,gen_random_uuid(),'No consent','03000000001','pickup','','',1000,'[]');
 if exists(select 1 from private.website_order_notifications where order_id=no_consent) then raise exception 'Consent bypass';end if;
 update private.website_notification_settings set enabled=true;
 update private.website_orders set status='confirmed' where id=o;
 if not exists(select 1 from private.website_order_notifications where order_id=o and event='pending' and status='skipped') then raise exception 'Stale message not superseded';end if;
 d:=public.store_notification_worker('{"action":"claim"}');
 select id,lease_id into n,lease from private.website_order_notifications where order_id=o and event='confirmed';
 if not exists(select 1 from private.website_order_notifications where id=n and status='sending' and attempts=1) then raise exception 'Claim failed';end if;
 if exists(select 1 from jsonb_array_elements(public.store_notification_worker('{"action":"claim"}'))x where x->>'id'=n::text) then raise exception 'Duplicate claim';end if;
 perform public.store_notification_worker(jsonb_build_object('action','finish','id',n,'lease_id',lease,'status','accepted','provider_id','verification-message-id'));
 perform public.store_notification_worker(jsonb_build_object('action','delivery','provider_id','verification-message-id','phone','923000000000','status','read'));
 perform public.store_notification_worker(jsonb_build_object('action','delivery','provider_id','verification-message-id','phone','923000000000','status','sent'));
 if not exists(select 1 from private.website_order_notifications where id=n and status='read') then raise exception 'Delivery regressed';end if;
 perform public.store_notification_worker('{"action":"stop","phone":"923000000000"}');
 update private.website_orders set status='cancelled' where id=o;
 if exists(select 1 from private.website_order_notifications where order_id=o and event='cancelled') then raise exception 'Opt out bypass';end if;
end $$;
set local role anon;
do $$begin begin perform public.store_notification_worker('{"action":"claim"}');raise exception 'Anonymous worker access';exception when insufficient_privilege then null;end;end$$;
reset role;
set local role authenticated;
do $$begin begin perform public.store_notification_worker('{"action":"claim"}');raise exception 'Customer worker access';exception when insufficient_privilege then null;end;end$$;
reset role;
rollback;
select 'Passed: consent, disabled mode, phone normalization, event deduplication, exclusive claims, monotonic delivery status, STOP and worker access isolation. No test messages sent; all test records rolled back.' as result;
