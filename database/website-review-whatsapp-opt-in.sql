-- Website review WhatsApp opt-in. No historical reviews are opted in.
alter table public.customers add column if not exists whatsapp_opt_in boolean;
alter table public.customers add column if not exists whatsapp_opt_in_at timestamptz;
alter table private.website_reviews add column if not exists whatsapp_opt_in boolean not null default false;
alter table private.website_reviews add column if not exists whatsapp_opt_in_at timestamptz;
alter table private.website_reviews add column if not exists customer_id uuid references public.customers(id) on delete set null;
create index if not exists website_reviews_customer_idx on private.website_reviews(customer_id) where customer_id is not null;
create or replace function private.website_review_submit(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v uuid; phone text; req uuid; existing private.website_reviews%rowtype; customer uuid; opted_in boolean:=coalesce(p->'whatsapp_opt_in','false'::jsonb)='true'::jsonb;
begin
 if coalesce(p->>'website','')<>'' then raise exception 'Unable to submit this review'; end if;
 if not coalesce((p->>'consent')::boolean,false) then raise exception 'Please agree to publication of your review'; end if;
 phone:=regexp_replace(coalesce(p->>'phone',''),'[^0-9]','','g');
 if phone like '0092%' then phone:=substring(phone from 3); end if;
 if phone like '03%' and length(phone)=11 then phone:='92'||substring(phone from 2); end if;
 if phone !~ '^[0-9]{10,15}$' then raise exception 'Enter a valid contact number'; end if;
 req:=(p->>'request_id')::uuid;
 if req is null then raise exception 'Missing submission reference'; end if;
 perform pg_advisory_xact_lock(hashtextextended('review:'||phone,0));
 select * into existing from private.website_reviews where request_id=req;
 if found then
  if existing.contact_phone<>phone then raise exception 'Submission reference already used'; end if;
  return jsonb_build_object('id',existing.id,'status','received');
 end if;
 if (select count(*) from private.website_reviews where contact_phone=phone and created_at>now()-interval '24 hours')>=3 then raise exception 'You have submitted several reviews today. Please try tomorrow'; end if;
 -- Only opted-in new contacts enter the ERP customer/greetings list.
 -- Existing names, balances and purchase history are never overwritten.
 perform pg_advisory_xact_lock(hashtextextended('website-customer:'||phone,0));
 select c.id into customer from public.customers c
 where (case
  when regexp_replace(coalesce(c.mobile,''),'[^0-9]','','g') ~ '^03[0-9]{9}$' then '92'||substring(regexp_replace(c.mobile,'[^0-9]','','g') from 2)
  when regexp_replace(coalesce(c.mobile,''),'[^0-9]','','g') like '0092%' then substring(regexp_replace(c.mobile,'[^0-9]','','g') from 3)
  else regexp_replace(coalesce(c.mobile,''),'[^0-9]','','g') end)=phone
 order by c.created_at,c.id limit 1;
 if opted_in then
  if customer is null then
   insert into public.customers(full_name,mobile,customer_kind,notes,whatsapp_opt_in,whatsapp_opt_in_at)
   values(trim(p->>'name'),case when phone ~ '^923[0-9]{9}$' then '0'||substring(phone from 3) else phone end,'customer','Website review contact · opted in to AppleSpace WhatsApp offers, updates and greetings.',true,now()) returning id into customer;
  else
   update public.customers set whatsapp_opt_in=true,whatsapp_opt_in_at=coalesce(whatsapp_opt_in_at,now()) where id=customer;
  end if;
 end if;
 insert into private.website_reviews(name,product,rating,body,consent,published,contact_phone,request_id,moderation_status,whatsapp_opt_in,whatsapp_opt_in_at,customer_id)
 values(trim(p->>'name'),trim(p->>'product'),(p->>'rating')::integer,trim(p->>'body'),true,false,phone,req,'pending',opted_in,case when opted_in then now() else null end,customer) returning id into v;
 return jsonb_build_object('id',v,'status','pending');
end;$$;
revoke all on function private.website_review_submit(jsonb) from public;
grant execute on function private.website_review_submit(jsonb) to anon,authenticated;
notify pgrst,'reload schema';
