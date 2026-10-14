-- Customer data is separate from ERP staff and CRM permissions.
create table private.website_customer_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 name text not null default '' check(length(name)<=100),
 phone text not null default '' check(length(phone)<=22),
 address text not null default '' check(length(address)<=600),
 updated_at timestamptz not null default now()
);
create table private.website_saved_products (
 user_id uuid not null references auth.users(id) on delete cascade,
 product_id uuid not null, created_at timestamptz not null default now(),
 primary key(user_id,product_id)
);
alter table private.website_customer_profiles enable row level security;
alter table private.website_saved_products enable row level security;
revoke all on private.website_customer_profiles,private.website_saved_products from public,anon,authenticated;
alter table private.website_orders add column customer_user_id uuid references auth.users(id) on delete set null;
create index website_orders_customer_idx on private.website_orders(customer_user_id,created_at desc) where customer_user_id is not null;
create function private.website_customer(p jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); a text:=coalesce(p->>'action','get'); result jsonb; pid uuid;
begin
 if u is null then raise exception 'Please sign in to your customer account' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text,1));
 if a='profile' then
  if length(trim(coalesce(p->>'name','')))<2 or length(p->>'name')>100 then raise exception 'Enter your full name'; end if;
  if regexp_replace(coalesce(p->>'phone',''),'[^0-9]','','g') !~ '^[0-9]{10,15}$' then raise exception 'Enter a valid phone number'; end if;
  if length(coalesce(p->>'address',''))>600 then raise exception 'Address is too long'; end if;
  insert into private.website_customer_profiles(user_id,name,phone,address) values(u,trim(p->>'name'),trim(p->>'phone'),trim(coalesce(p->>'address','')))
  on conflict(user_id) do update set name=excluded.name,phone=excluded.phone,address=excluded.address,updated_at=now();
 elsif a in ('save','remove') then
  pid:=(p->>'product_id')::uuid;
  if a='remove' then delete from private.website_saved_products where user_id=u and product_id=pid;
  else
   if not exists(select 1 from jsonb_array_elements(private.website_products(false)) x where x->>'id'=pid::text) then raise exception 'This product is unavailable'; end if;
   if (select count(*) from private.website_saved_products where user_id=u)>=100 and not exists(select 1 from private.website_saved_products where user_id=u and product_id=pid) then raise exception 'You can save up to 100 products'; end if;
   insert into private.website_saved_products(user_id,product_id) values(u,pid) on conflict do nothing;
  end if;
 elsif a<>'get' then raise exception 'Unknown account action'; end if;
 return jsonb_build_object(
 'profile',coalesce((select jsonb_build_object('name',name,'phone',phone,'address',address) from private.website_customer_profiles where user_id=u),'{}'::jsonb),
 'saved',coalesce((select jsonb_agg(product_id order by created_at desc) from private.website_saved_products where user_id=u),'[]'::jsonb),
 'orders',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from (select id,status,total,items,fulfilment,created_at,confirmed_at,dispatched_at,completed_at,courier,tracking_number from private.website_orders where customer_user_id=u order by created_at desc limit 100)o),'[]'::jsonb));
end $$;
revoke all on function private.website_customer(jsonb) from public,anon;
grant execute on function private.website_customer(jsonb) to authenticated;
create function public.store_customer(p jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select private.website_customer(p)$$;
revoke all on function public.store_customer(jsonb) from public,anon;
grant execute on function public.store_customer(jsonb) to authenticated;
do $patch$ declare src text; begin
 select pg_get_functiondef('private.website_checkout(jsonb)'::regprocedure) into src;
 src:=replace(src,'if existing.phone<>v_phone then','if existing.customer_user_id is distinct from auth.uid() or existing.phone<>v_phone then');
 src:=replace(src,'website_orders(request_id,customer_name','website_orders(customer_user_id,request_id,customer_name');
 src:=replace(src,'values((p->>''request_id'')::uuid','values(auth.uid(),(p->>''request_id'')::uuid');
 execute src;
end $patch$;
