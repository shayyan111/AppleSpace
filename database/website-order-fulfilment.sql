-- Atomic website fulfilment. Payment collection remains in the ERP.
alter table private.website_orders drop constraint website_orders_status_check;
alter table private.website_orders add constraint website_orders_status_check check(status in ('pending','confirmed','dispatched','completed','cancelled'));
alter table private.website_orders add column confirmed_at timestamptz, add column dispatched_at timestamptz, add column completed_at timestamptz, add column cancelled_at timestamptz, add column courier text, add column tracking_number text, add column sale_id uuid references public.sales(id) on delete restrict;
alter table public.sales add column website_order_id uuid unique references private.website_orders(id) on delete restrict;
alter table public.inventory_items add column website_order_id uuid references private.website_orders(id) on delete restrict;
create index website_orders_status_created_idx on private.website_orders(status,created_at desc);
create or replace function private.website_fulfil_order(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare o private.website_orders; s text:=p->>'status'; line jsonb; phone public.inventory_items; accessory public.accessories; customer uuid; sale uuid; item_id uuid; actor uuid; qty integer; cost numeric:=0; total numeric:=0; v_mobile text;
begin
 if auth.uid() is null or not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 select * into o from private.website_orders where id=(p->>'id')::uuid for update;
 if not found then raise exception 'Order not found'; end if;
 if s is null or s not in ('pending','confirmed','dispatched','completed','cancelled') then raise exception 'Invalid order status'; end if;
 if o.status=s then return jsonb_build_object('id',o.id,'sale_id',o.sale_id,'ok',true); end if;
 if not ((o.status='pending' and s in ('confirmed','cancelled')) or (o.status='confirmed' and s in ('dispatched','completed','cancelled')) or (o.status='dispatched' and s in ('completed','cancelled'))) then raise exception 'This order cannot move to that status'; end if;
 if s='dispatched' and o.fulfilment<>'delivery' then raise exception 'Collection orders do not need dispatch'; end if;
 if length(coalesce(p->>'courier',''))>100 or length(coalesce(p->>'tracking_number',''))>120 then raise exception 'Courier or tracking number too long'; end if;
 if s in ('confirmed','dispatched','completed') then
  -- Same lock order as ERP sales: phones first, then accessories. No partial sale on failure.
  for line in select value from jsonb_array_elements(o.items) order by case when value->>'kind'='iphone' then 0 else 1 end,value->>'id' loop
   qty:=(line->>'quantity')::integer;
   if qty is null or qty<1 or (line->>'price')::numeric<=0 then raise exception 'Invalid order item'; end if;
   if line->>'kind'='iphone' then
    select * into phone from public.inventory_items where id=(line->>'id')::uuid for update;
    if not found or phone.status<>'in_stock' or qty<>1 or exists(select 1 from public.sale_items where inventory_item_id=phone.id) then raise exception 'A phone is no longer available. Resolve stock before continuing'; end if;
    if s='completed' and phone.purchase_cost_pending then raise exception 'Owner must complete the phone purchase record in ERP first'; end if;
   elsif line->>'kind'='accessory' then
    select * into accessory from public.accessories where id=(line->>'id')::uuid for update;
    if not found or accessory.quantity<qty then raise exception 'Insufficient accessory stock'; end if;
   else raise exception 'Unsupported order item'; end if;
   total:=total+(line->>'price')::numeric*qty;
  end loop;
  if total<>o.total then raise exception 'Order total needs reconciliation'; end if;
 end if;
 if s='completed' then
  if o.sale_id is not null then raise exception 'This order already has a linked sale'; end if;
  v_mobile:=regexp_replace(o.phone,'[^0-9]','','g');
  if v_mobile like '0092%' then v_mobile:=substring(v_mobile from 3); end if;
  if v_mobile ~ '^03[0-9]{9}$' then v_mobile:='92'||substring(v_mobile from 2); end if;
  perform pg_advisory_xact_lock(hashtextextended('website-customer:'||v_mobile,0));
  select c.id into customer from public.customers c where
   (case when regexp_replace(coalesce(c.mobile,''),'[^0-9]','','g') ~ '^03[0-9]{9}$' then '92'||substring(regexp_replace(c.mobile,'[^0-9]','','g') from 2) when regexp_replace(coalesce(c.mobile,''),'[^0-9]','','g') like '0092%' then substring(regexp_replace(c.mobile,'[^0-9]','','g') from 3) else regexp_replace(coalesce(c.mobile,''),'[^0-9]','','g') end)=v_mobile and c.customer_kind='customer' order by c.created_at,c.id limit 1;
  if customer is null then insert into public.customers(full_name,mobile,address,notes) values(o.customer_name,case when v_mobile ~ '^923[0-9]{9}$' then '0'||substring(v_mobile from 3) else v_mobile end,o.address,'Website order customer; no marketing consent recorded') returning id into customer; end if;
  select id into actor from public.user_profiles where id=auth.uid() and is_active;
  insert into public.sales(invoice_number,customer_id,subtotal,final_total,payment_status,sold_by,billed_by,billed_by_name,notes,website_order_id)
   values('WEB-'||upper(o.id::text),customer,o.total,o.total,'unpaid',actor,actor,'Website fulfilment','Sold through website. Order '||upper(o.id::text)||'. Delivery confirmed; payment must be recorded separately.',o.id) returning id into sale;
  for line in select value from jsonb_array_elements(o.items) order by case when value->>'kind'='iphone' then 0 else 1 end,value->>'id' loop
   qty:=(line->>'quantity')::integer;
   if line->>'kind'='iphone' then
    select * into phone from public.inventory_items where id=(line->>'id')::uuid;
    insert into public.sale_items(sale_id,inventory_item_id,item_name,quantity,unit_price,final_price,phone_details) values(sale,phone.id,line->>'title',qty,(line->>'price')::numeric,(line->>'price')::numeric*qty,jsonb_strip_nulls(jsonb_build_object('model',phone.model,'storage',phone.storage,'color',phone.color,'imei_1',phone.imei_1,'imei_2',phone.imei_2,'pta_status',phone.pta_status,'battery_health',phone.battery_health,'condition_grade',phone.condition_grade,'warranty_notes',phone.warranty_notes))) returning id into item_id;
    insert into public.sale_item_costs(sale_item_id,cost_price_snapshot) values(item_id,phone.purchase_price);
    cost:=cost+phone.purchase_price;
    update public.inventory_items set status='sold',sold_at=now(),website_order_id=o.id,public_notes=concat_ws(E'\n',nullif(public_notes,''),'Sold through website · '||upper(substr(o.id::text,1,8))) where id=phone.id;
    insert into public.stock_movements(inventory_item_id,movement_type,from_status,to_status,reference_type,reference_id,notes,created_by) values(phone.id,'sale','in_stock','sold','sale',sale,'Sold through website',actor);
   else
    select * into accessory from public.accessories where id=(line->>'id')::uuid;
    insert into public.sale_items(sale_id,accessory_id,item_name,quantity,unit_price,final_price) values(sale,accessory.id,line->>'title',qty,(line->>'price')::numeric,(line->>'price')::numeric*qty) returning id into item_id;
    insert into public.sale_item_costs(sale_item_id,cost_price_snapshot) values(item_id,accessory.purchase_price*qty);
    cost:=cost+accessory.purchase_price*qty;
    update public.accessories set quantity=quantity-qty,updated_at=now() where id=accessory.id;
   end if;
  end loop;
  perform private.erp_post('sale',sale,'Sold through website',jsonb_build_array(jsonb_build_object('account','1100','debit',o.total),jsonb_build_object('account','4000','credit',o.total),jsonb_build_object('account','5000','debit',cost),jsonb_build_object('account','1200','credit',cost)));
 end if;
 update private.website_orders set status=s,updated_at=now(),confirmed_at=case when s='confirmed' then now() else confirmed_at end,dispatched_at=case when s='dispatched' then now() else dispatched_at end,completed_at=case when s='completed' then now() else completed_at end,cancelled_at=case when s='cancelled' then now() else cancelled_at end,courier=coalesce(nullif(trim(p->>'courier'),''),courier),tracking_number=coalesce(nullif(trim(p->>'tracking_number'),''),tracking_number),sale_id=coalesce(sale,sale_id) where id=o.id;
 return jsonb_build_object('id',o.id,'sale_id',sale,'ok',true);
end; $$;
revoke all on function private.website_fulfil_order(jsonb) from public,anon,authenticated;
-- Route the existing protected mutation through the atomic transition function.
do $$ declare src text; begin
 select pg_get_functiondef('private.website_update(jsonb)'::regprocedure) into src;
 src:=regexp_replace(src,'elsif a=''order_status'' then.*?elsif a=''manager'' then', 'elsif a=''order_status'' then return private.website_fulfil_order(p); elsif a=''manager'' then','s');
 execute src;
end $$;
create or replace function private.website_order_list(bucket text default 'active',page_number integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 if bucket is null or bucket not in ('active','completed','cancelled') or page_number is null or page_number<0 or page_number>100000 then raise exception 'Invalid order filter'; end if;
 return jsonb_build_object('orders',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id) from (select o.id,o.customer_name,o.phone,o.fulfilment,o.address,o.notes,o.status,o.total,o.items,o.created_at,o.confirmed_at,o.dispatched_at,o.completed_at,o.cancelled_at,o.courier,o.tracking_number,o.sale_id,s.invoice_number,s.payment_status from private.website_orders o left join public.sales s on s.id=o.sale_id where (bucket='active' and o.status in ('pending','confirmed','dispatched')) or o.status=bucket order by o.created_at desc,o.id limit 30 offset page_number*30)x),'[]'::jsonb),'total',(select count(*) from private.website_orders o where (bucket='active' and o.status in ('pending','confirmed','dispatched')) or o.status=bucket));
end $$;
revoke all on function private.website_order_list(text,integer) from public,anon;
grant execute on function private.website_order_list(text,integer) to authenticated;
create or replace function public.store_order_list(bucket text default 'active',page_number integer default 0) returns jsonb language sql set search_path='' as $$ select private.website_order_list(bucket,page_number); $$;
revoke all on function public.store_order_list(text,integer) from public,anon;
grant execute on function public.store_order_list(text,integer) to authenticated;
