-- Full end-to-end database checks, with synthetic records rolled back.
begin;
do $$
declare
 phone text; canon text; other text; existing_phone text;
 req uuid:=gen_random_uuid(); r jsonb; again jsonb; cust uuid; known uuid;
 p jsonb; before_count bigint;
begin
 loop
  phone:='0399'||lpad((floor(random()*10000000)::bigint)::text,7,'0');
  canon:='92'||substring(phone from 2);
  exit when not exists(select 1 from public.customers where mobile in(phone,canon)) and not exists(select 1 from private.website_reviews where contact_phone=canon);
 end loop;
 p:=jsonb_build_object('request_id',req,'name','Website opt-in test','phone',phone,'product','Test device','rating',5,'body','Synthetic integration test review.','consent',true,'whatsapp_opt_in',true);
 execute 'set local role anon';
 r:=public.store_review_submit(p);
 execute 'reset role';
 select id into cust from public.customers where mobile=phone;
 if cust is null or not exists(select 1 from public.customers where id=cust and whatsapp_opt_in and whatsapp_opt_in_at is not null) then raise exception 'Opted-in reviewer was not added'; end if;
 if not exists(select 1 from private.website_reviews where id=(r->>'id')::uuid and customer_id=cust and whatsapp_opt_in and whatsapp_opt_in_at is not null and not published and moderation_status='pending') then raise exception 'Review/consent link missing or review bypassed moderation'; end if;
 execute 'set local role anon';
 again:=public.store_review_submit(p||jsonb_build_object('phone','+'||canon));
 perform public.store_review_submit(p||jsonb_build_object('request_id',gen_random_uuid(),'phone','0092'||substring(phone from 2),'name','Do not overwrite customer'));
 execute 'reset role';
 if again->>'id'<>r->>'id' or (select count(*) from public.customers where mobile in(phone,canon))<>1 then raise exception 'Retry or phone formats created a duplicate'; end if;
 if (select full_name from public.customers where id=cust)<>'Website opt-in test' then raise exception 'Existing customer name overwritten'; end if;
 if exists(select 1 from jsonb_array_elements(public.store_reviews()) x where x->>'id'=r->>'id') then raise exception 'Pending review appeared publicly'; end if;
 if exists(select 1 from jsonb_array_elements(public.store_reviews()) x where x ? 'contact_phone' or x ? 'customer_id' or x ? 'whatsapp_opt_in') then raise exception 'Private customer fields leaked'; end if;
 other:='0388'||substring(phone from 5);
 select count(*) into before_count from public.customers;
 execute 'set local role anon';
 perform public.store_review_submit(p||jsonb_build_object('request_id',gen_random_uuid(),'phone',other,'whatsapp_opt_in',false));
 execute 'reset role';
 if (select count(*) from public.customers)<>before_count then raise exception 'Unchecked consent created a customer'; end if;
 existing_phone:='0377'||substring(phone from 5);
 insert into public.customers(full_name,mobile,notes) values('Existing CRM customer',existing_phone,'Original history notes') returning id into known;
 execute 'set local role anon';
 r:=public.store_review_submit(p||jsonb_build_object('request_id',gen_random_uuid(),'phone','+92'||substring(existing_phone from 2),'name','Different review display name'));
 execute 'reset role';
 if not exists(select 1 from private.website_reviews where id=(r->>'id')::uuid and customer_id=known) then raise exception 'Existing CRM contact not matched'; end if;
 if not exists(select 1 from public.customers where id=known and full_name='Existing CRM customer' and notes='Original history notes' and whatsapp_opt_in) then raise exception 'Existing CRM contact changed incorrectly'; end if;
 execute 'set local role anon';
 if exists(select 1 from public.customers where id in(cust,known)) then raise exception 'Anonymous customer read exposed private contacts'; end if;
 begin
  insert into public.customers(full_name,mobile) values('Unauthorized anonymous contact','03000000000');
  raise exception 'Anonymous direct customer insert was allowed';
 exception when insufficient_privilege then null;
 end;
 execute 'reset role';
 raise notice 'PASS: opted-in contacts, normalized matching, retries, unchecked consent, existing customer preservation, pending moderation and customer privacy';
end $$;
rollback;
