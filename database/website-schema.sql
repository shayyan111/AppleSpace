begin;
-- Website-only accounts have no ERP role and cannot access purchase tables/RPCs.
create table private.website_managers (
 user_id uuid primary key references auth.users(id) on delete cascade,
 active boolean not null default true, created_at timestamptz not null default now()
);
alter table private.website_managers enable row level security;
create function private.website_can_manage() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and (
  private.current_app_role()='owner'::public.app_role or
  (private.current_app_role() is null and exists(select 1 from private.website_managers where user_id=auth.uid() and active))
 );
$$;
revoke all on function private.website_can_manage() from public,anon;
grant execute on function private.website_can_manage() to authenticated;

create table private.website_accessory_content (
 accessory_id uuid primary key references public.accessories(id) on delete cascade,
 published boolean not null default false, title text, description text,
 price numeric(14,2) check(price>0), updated_at timestamptz not null default now()
);
create table private.website_media (
 id uuid primary key default gen_random_uuid(),
 inventory_item_id uuid references public.inventory_items(id) on delete cascade,
 accessory_id uuid references public.accessories(id) on delete cascade,
 object_path text not null unique, alt_text text not null default '',
 sort_order integer not null default 0, created_at timestamptz not null default now(),
 check(num_nonnulls(inventory_item_id,accessory_id)=1)
);
create index website_media_phone_idx on private.website_media(inventory_item_id);
create index website_media_accessory_idx on private.website_media(accessory_id);
create table private.website_orders (
 id uuid primary key default gen_random_uuid(), request_id uuid not null unique,
 customer_name text not null, phone text not null, fulfilment text not null check(fulfilment in ('pickup','delivery')),
 address text not null default '', notes text not null default '',
 status text not null default 'pending' check(status in ('pending','confirmed','completed','cancelled')),
 total numeric(14,2) not null check(total>0), items jsonb not null,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index website_orders_phone_date_idx on private.website_orders(phone,created_at);
alter table private.website_accessory_content enable row level security;
alter table private.website_media enable row level security;
alter table private.website_orders enable row level security;
revoke all on private.website_managers,private.website_accessory_content,private.website_media,private.website_orders from public,anon,authenticated;

-- Explicit field whitelist: never serialize inventory rows, internal notes or costs.
create function private.website_products(manage boolean default false) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if manage and not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(p order by p->>'created_at' desc) from (
 select jsonb_build_object('id',i.id,'kind','iphone','title',coalesce(nullif(i.website_title,''),i.model),
 'model',i.model,'storage',i.storage,'color',i.color,'battery_health',i.battery_health,'pta_status',i.pta_status,
 'condition',i.condition_grade,'price',coalesce(i.website_price,i.default_sale_price),'description',coalesce(i.website_description,''),
 'quantity',case when i.status='in_stock' then 1 else 0 end,'status',i.status,
 'published',i.show_on_website,'stock_code',case when manage then i.stock_code else null end,
 'created_at',i.created_at,'images',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'path',m.object_path,'alt',m.alt_text) order by m.sort_order,m.created_at) from private.website_media m where m.inventory_item_id=i.id),'[]'::jsonb)) p
 from public.inventory_items i where i.status<>'sold' and (manage or (i.status='in_stock' and i.show_on_website and coalesce(i.website_price,i.default_sale_price)>0))
 union all
 select jsonb_build_object('id',a.id,'kind','accessory','title',coalesce(nullif(w.title,''),a.name),'model',a.name,'category',a.category,
 'price',coalesce(w.price,a.sale_price),'description',coalesce(w.description,''),'quantity',greatest(a.quantity,0),
 'status',case when a.quantity>0 then 'in_stock' else 'out_of_stock' end,'published',coalesce(w.published,false),
 'stock_code',case when manage then a.sku else null end,'created_at',a.created_at,
 'images',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'path',m.object_path,'alt',m.alt_text) order by m.sort_order,m.created_at) from private.website_media m where m.accessory_id=a.id),'[]'::jsonb))
 from public.accessories a left join private.website_accessory_content w on w.accessory_id=a.id
 where manage or (a.quantity>0 and w.published and coalesce(w.price,a.sale_price)>0)
 )q),'[]'::jsonb);
end;$$;
revoke all on function private.website_products(boolean) from public;
grant execute on function private.website_products(boolean) to anon,authenticated;
create function public.store_catalog() returns jsonb language sql security invoker set search_path='' as $$select private.website_products(false);$$;
revoke all on function public.store_catalog() from public;
grant execute on function public.store_catalog() to anon,authenticated;

create function private.website_portal() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 return jsonb_build_object('owner',private.current_app_role()='owner'::public.app_role,'products',private.website_products(true),
 'orders',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from (select id,customer_name,phone,fulfilment,address,notes,status,total,items,created_at from private.website_orders order by created_at desc limit 200)o),'[]'::jsonb),
 'managers',case when private.current_app_role()='owner'::public.app_role then coalesce((select jsonb_agg(jsonb_build_object('user_id',w.user_id,'email',u.email,'active',w.active)) from private.website_managers w join auth.users u on u.id=w.user_id),'[]'::jsonb) else '[]'::jsonb end);
end;$$;
revoke all on function private.website_portal() from public,anon;
grant execute on function private.website_portal() to authenticated;
create function public.store_portal() returns jsonb language sql security invoker set search_path='' as $$select private.website_portal();$$;
revoke all on function public.store_portal() from public,anon;
grant execute on function public.store_portal() to authenticated;

create function private.website_update(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v uuid; a text:=p->>'action'; price numeric; media private.website_media%rowtype;
begin
 if not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 if a='listing' then
  price:=nullif(p->>'price','')::numeric;
  if (p->>'published')::boolean and (price is null or price<=0) then raise exception 'Enter a positive selling price before publishing'; end if;
  if length(coalesce(p->>'title',''))>160 or length(coalesce(p->>'description',''))>5000 then raise exception 'Title or description too long'; end if;
  if p->>'kind'='iphone' then
   update public.inventory_items set show_on_website=(p->>'published')::boolean,website_price=price,website_title=nullif(trim(p->>'title'),''),website_description=p->>'description'
   where id=(p->>'id')::uuid and (status='in_stock' or not (p->>'published')::boolean) returning id into v;
  elsif p->>'kind'='accessory' then
   perform 1 from public.accessories where id=(p->>'id')::uuid and (quantity>0 or not (p->>'published')::boolean) for update;
   if not found then raise exception 'This accessory is unavailable'; end if;
   insert into private.website_accessory_content(accessory_id,published,title,description,price) values((p->>'id')::uuid,(p->>'published')::boolean,nullif(trim(p->>'title'),''),p->>'description',price)
   on conflict(accessory_id) do update set published=excluded.published,title=excluded.title,description=excluded.description,price=excluded.price,updated_at=now() returning accessory_id into v;
  end if;
  if v is null then raise exception 'This product is unavailable'; end if;
 elsif a='media_add' then
  if p->>'kind'='iphone' then perform 1 from public.inventory_items where id=(p->>'id')::uuid and status<>'sold' for update;
  elsif p->>'kind'='accessory' then perform 1 from public.accessories where id=(p->>'id')::uuid for update;
  else raise exception 'Invalid product type'; end if;
  if not found then raise exception 'Product not found'; end if;
  if split_part(p->>'path','/',1)<>auth.uid()::text or not exists(select 1 from storage.objects where bucket_id='website-products' and name=p->>'path') then raise exception 'Upload a product image first'; end if;
  if (select count(*) from private.website_media where inventory_item_id=(p->>'id')::uuid or accessory_id=(p->>'id')::uuid)>=8 then raise exception 'Maximum eight photos per product'; end if;
  insert into private.website_media(inventory_item_id,accessory_id,object_path,alt_text,sort_order) values(case when p->>'kind'='iphone' then (p->>'id')::uuid end,case when p->>'kind'='accessory' then (p->>'id')::uuid end,p->>'path',left(coalesce(p->>'alt',''),200),coalesce((p->>'sort_order')::integer,0)) returning id into v;
 elsif a='media_remove' then
  delete from private.website_media where id=(p->>'media_id')::uuid returning id into v;
  if v is null then raise exception 'Image not found'; end if;
 elsif a='media_cover' then
  select * into media from private.website_media where id=(p->>'media_id')::uuid;
  if not found then raise exception 'Image not found'; end if;
  update private.website_media set sort_order=1 where inventory_item_id=media.inventory_item_id or accessory_id=media.accessory_id;
  update private.website_media set sort_order=0 where id=media.id returning id into v;
 elsif a='order_status' then
  if p->>'status' not in ('pending','confirmed','completed','cancelled') then raise exception 'Invalid order status'; end if;
  update private.website_orders set status=p->>'status',updated_at=now() where id=(p->>'id')::uuid returning id into v;
  if v is null then raise exception 'Order not found'; end if;
 elsif a='manager' then
  if private.current_app_role() is distinct from 'owner'::public.app_role then raise exception 'Owner access required'; end if;
  select id into v from auth.users where lower(email)=lower(trim(p->>'email'));
  if v is null then raise exception 'Create this account in Supabase Authentication first'; end if;
  if exists(select 1 from public.user_profiles where id=v and is_active) then raise exception 'Use a separate website-only account without an ERP staff role'; end if;
  insert into private.website_managers(user_id,active) values(v,coalesce((p->>'active')::boolean,true)) on conflict(user_id) do update set active=excluded.active;
 else raise exception 'Unknown action'; end if;
 return jsonb_build_object('id',v,'ok',true);
end;$$;
revoke all on function private.website_update(jsonb) from public,anon;
grant execute on function private.website_update(jsonb) to authenticated;
create function public.store_update(p jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.website_update(p);$$;
revoke all on function public.store_update(jsonb) from public,anon;
grant execute on function public.store_update(jsonb) to authenticated;

-- Orders use database prices and re-check stock; no costs leave the database.
create function private.website_checkout(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare row jsonb; prod jsonb; items jsonb:='[]'; qty integer; total numeric:=0; id uuid; v_phone text; existing private.website_orders%rowtype;
begin
 if length(trim(coalesce(p->>'name','')))<2 or length(p->>'name')>100 then raise exception 'Enter your full name'; end if;
 v_phone:=regexp_replace(coalesce(p->>'phone',''),'[^0-9+]','','g');
 if v_phone !~ '^\+?[0-9]{10,15}$' then raise exception 'Enter a valid phone number'; end if;
 if p->>'fulfilment' not in ('pickup','delivery') then raise exception 'Choose pickup or delivery'; end if;
 if p->>'fulfilment'='delivery' and length(trim(coalesce(p->>'address','')))<10 then raise exception 'Enter your complete delivery address'; end if;
 if length(coalesce(p->>'address',''))>600 or length(coalesce(p->>'notes',''))>1000 then raise exception 'Address or notes too long'; end if;
 if jsonb_typeof(p->'items') is distinct from 'array' or jsonb_array_length(p->'items') not between 1 and 20 then raise exception 'Cart must contain 1–20 products'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_phone,0));
 select * into existing from private.website_orders where request_id=(p->>'request_id')::uuid;
 if found then
  if existing.phone<>v_phone then raise exception 'Request already used'; end if;
  return jsonb_build_object('id',existing.id,'total',existing.total);
 end if;
 if (select count(*) from private.website_orders where website_orders.phone=v_phone and created_at>now()-interval '1 hour')>=5 then raise exception 'Too many requests. Please contact the shop'; end if;
 if exists(select 1 from jsonb_array_elements(p->'items') x group by x->>'id',x->>'kind' having count(*)>1) then raise exception 'Duplicate cart items'; end if;
 for row in select * from jsonb_array_elements(p->'items') loop
  qty:=(row->>'quantity')::integer;
  if qty is null or qty not between 1 and 20 then raise exception 'Invalid quantity'; end if;
  -- Lock canonical stock during validation. Requests do not reserve or sell it.
  if row->>'kind'='iphone' then perform 1 from public.inventory_items where inventory_items.id=(row->>'id')::uuid for share;
  elsif row->>'kind'='accessory' then perform 1 from public.accessories where accessories.id=(row->>'id')::uuid for share;
  else raise exception 'Invalid product type'; end if;
  select x into prod from jsonb_array_elements(private.website_products(false)) x where x->>'id'=row->>'id' and x->>'kind'=row->>'kind';
  if prod is null or qty>(prod->>'quantity')::integer then raise exception 'A product is no longer available. Refresh your cart'; end if;
  if nullif(row->>'price','')::numeric is distinct from (prod->>'price')::numeric then raise exception 'A price changed. Refresh your cart before submitting'; end if;
  total:=total+(prod->>'price')::numeric*qty;
  items:=items||jsonb_build_array(jsonb_build_object('id',prod->>'id','kind',prod->>'kind','title',prod->>'title','quantity',qty,'price',(prod->>'price')::numeric));
 end loop;
 insert into private.website_orders(request_id,customer_name,phone,fulfilment,address,notes,total,items) values((p->>'request_id')::uuid,trim(p->>'name'),v_phone,p->>'fulfilment',coalesce(p->>'address',''),coalesce(p->>'notes',''),total,items) returning website_orders.id into id;
 return jsonb_build_object('id',id,'total',total);
end;$$;
revoke all on function private.website_checkout(jsonb) from public;
grant execute on function private.website_checkout(jsonb) to anon,authenticated;
create function public.store_checkout(p jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.website_checkout(p);$$;
revoke all on function public.store_checkout(jsonb) from public;
grant execute on function public.store_checkout(jsonb) to anon,authenticated;

-- Only managers upload product imagery, with user-owned paths and MIME/size limits.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('website-products','website-products',true,5242880,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
create policy website_image_insert on storage.objects for insert to authenticated with check(bucket_id='website-products' and private.website_can_manage() and (storage.foldername(name))[1]=auth.uid()::text);
create policy website_image_manage_read on storage.objects for select to authenticated using(bucket_id='website-products' and private.website_can_manage());
create policy website_image_delete on storage.objects for delete to authenticated using(bucket_id='website-products' and private.website_can_manage() and (storage.foldername(name))[1]=auth.uid()::text);
grant usage on schema private to anon,authenticated;
notify pgrst,'reload schema';
commit;
