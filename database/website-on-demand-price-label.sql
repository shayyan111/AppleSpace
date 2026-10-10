alter table private.website_on_demand add column if not exists price_label text not null default 'Call us for price' check(length(trim(price_label)) between 1 and 80);
CREATE OR REPLACE FUNCTION private.website_products(manage boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 union all
 select jsonb_build_object('id',d.id,'kind','on_demand','listing_source','website_only','category',d.category,'title',d.title,'model',d.model,
 'storage',d.storage,'color',d.color,'battery_health',d.battery_health,'pta_status',d.pta_status,'condition',d.condition,
 'price',d.price,'price_label',d.price_label,'description',d.description,'quantity',0,'status','on_demand','published',d.published,'stock_code',null,'created_at',d.created_at,
 'images',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'path',m.object_path,'alt',m.alt_text) order by m.sort_order,m.created_at) from private.website_media m where m.on_demand_id=d.id),'[]'::jsonb))
 from private.website_on_demand d where manage or d.published
 )q),'[]'::jsonb);
end;$function$
;
CREATE OR REPLACE FUNCTION private.website_update(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v uuid; a text:=p->>'action'; v_price numeric; media private.website_media%rowtype;
begin
 if not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 if a='on_demand_save' then
  if length(trim(coalesce(p->>'price_label','')))>80 then raise exception 'Price message must be 80 characters or fewer'; end if;
  if p->>'category' is null or p->>'category' not in ('iphones','ipads','accessories') then raise exception 'Choose a product category'; end if;
  if length(trim(coalesce(p->>'title','')))<2 or length(p->>'title')>160 then raise exception 'Enter a product title (2–160 characters)'; end if;
  if length(trim(coalesce(p->>'model','')))<2 or length(p->>'model')>160 then raise exception 'Enter a model or product name (2–160 characters)'; end if;
  if length(coalesce(p->>'description',''))>5000 or length(coalesce(p->>'storage',''))>40 or length(coalesce(p->>'color',''))>80 or length(coalesce(p->>'condition',''))>160 then raise exception 'Product details too long'; end if;
  v_price:=nullif(p->>'price','')::numeric;
  if v_price is not null and (v_price<=0 or v_price='NaN'::numeric or v_price='Infinity'::numeric) then raise exception 'Enter a positive price, or leave it empty for a quote'; end if;
  if nullif(p->>'pta_status','') is not null and p->>'pta_status' not in ('pta_approved','non_pta','jv') then raise exception 'Invalid network status'; end if;
  if p->>'id' is null or p->>'id'='' then
   insert into private.website_on_demand(title,model,category,storage,color,battery_health,pta_status,condition,price,price_label,description,published,created_by)
   values(trim(p->>'title'),trim(p->>'model'),p->>'category',nullif(trim(p->>'storage'),''),nullif(trim(p->>'color'),''),nullif(p->>'battery_health','')::integer,nullif(p->>'pta_status',''),nullif(trim(p->>'condition'),''),v_price,coalesce(nullif(trim(p->>'price_label'),''),'Call us for price'),coalesce(p->>'description',''),coalesce((p->>'published')::boolean,false),auth.uid()) returning id into v;
  else
   update private.website_on_demand set title=trim(p->>'title'),model=trim(p->>'model'),category=p->>'category',storage=nullif(trim(p->>'storage'),''),color=nullif(trim(p->>'color'),''),battery_health=nullif(p->>'battery_health','')::integer,pta_status=nullif(p->>'pta_status',''),condition=nullif(trim(p->>'condition'),''),price=v_price,price_label=coalesce(nullif(trim(p->>'price_label'),''),'Call us for price'),description=coalesce(p->>'description',''),published=coalesce((p->>'published')::boolean,false),updated_at=now()
   where id=(p->>'id')::uuid returning id into v;
   if v is null then raise exception 'On-demand listing not found'; end if;
  end if;
 elsif a='on_demand_delete' then
  delete from private.website_on_demand where id=(p->>'id')::uuid returning id into v;
  if v is null then raise exception 'On-demand listing not found'; end if;
 elsif a='listing' then
  v_price:=nullif(p->>'price','')::numeric;
  if (p->>'published')::boolean and (v_price is null or v_price<=0) then raise exception 'Enter a positive selling price before publishing'; end if;
  if length(coalesce(p->>'title',''))>160 or length(coalesce(p->>'description',''))>5000 then raise exception 'Title or description too long'; end if;
  if p->>'kind'='iphone' then
   update public.inventory_items set show_on_website=(p->>'published')::boolean,website_price=v_price,website_title=nullif(trim(p->>'title'),''),website_description=p->>'description'
   where id=(p->>'id')::uuid and (status='in_stock' or not (p->>'published')::boolean) returning id into v;
  elsif p->>'kind'='accessory' then
   perform 1 from public.accessories where id=(p->>'id')::uuid and (quantity>0 or not (p->>'published')::boolean) for update;
   if not found then raise exception 'This accessory is unavailable'; end if;
   insert into private.website_accessory_content(accessory_id,published,title,description,price) values((p->>'id')::uuid,(p->>'published')::boolean,nullif(trim(p->>'title'),''),p->>'description',v_price)
   on conflict(accessory_id) do update set published=excluded.published,title=excluded.title,description=excluded.description,price=excluded.price,updated_at=now() returning accessory_id into v;
  end if;
  if v is null then raise exception 'This product is unavailable'; end if;
 elsif a='media_add' then
  if p->>'kind'='iphone' then perform 1 from public.inventory_items where id=(p->>'id')::uuid and status<>'sold' for update;
  elsif p->>'kind'='accessory' then perform 1 from public.accessories where id=(p->>'id')::uuid for update;
  elsif p->>'kind'='on_demand' then perform 1 from private.website_on_demand where id=(p->>'id')::uuid for update;
  else raise exception 'Invalid product type'; end if;
  if not found then raise exception 'Product not found'; end if;
  if split_part(p->>'path','/',1)<>auth.uid()::text or not exists(select 1 from storage.objects where bucket_id='website-products' and name=p->>'path') then raise exception 'Upload a product image first'; end if;
  if (select count(*) from private.website_media where inventory_item_id=(p->>'id')::uuid or accessory_id=(p->>'id')::uuid or on_demand_id=(p->>'id')::uuid)>=8 then raise exception 'Maximum eight photos per product'; end if;
  insert into private.website_media(inventory_item_id,accessory_id,on_demand_id,object_path,alt_text,sort_order) values(case when p->>'kind'='iphone' then (p->>'id')::uuid end,case when p->>'kind'='accessory' then (p->>'id')::uuid end,case when p->>'kind'='on_demand' then (p->>'id')::uuid end,p->>'path',left(coalesce(p->>'alt',''),200),coalesce((p->>'sort_order')::integer,0)) returning id into v;
 elsif a='media_remove' then
  delete from private.website_media where id=(p->>'media_id')::uuid returning id into v;
  if v is null then raise exception 'Image not found'; end if;
 elsif a='media_cover' then
  select * into media from private.website_media where id=(p->>'media_id')::uuid;
  if not found then raise exception 'Image not found'; end if;
  update private.website_media set sort_order=1 where inventory_item_id=media.inventory_item_id or accessory_id=media.accessory_id or on_demand_id=media.on_demand_id;
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
end;$function$
;
notify pgrst,'reload schema';
