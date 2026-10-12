-- Confirmed stock belongs to an order until completion or safe cancellation.
alter table private.website_orders drop constraint website_orders_status_check;
alter table private.website_orders add constraint website_orders_status_check check(status in ('pending','confirmed','dispatched','completed','cancelled','return_pending'));
alter table private.website_orders add column reserved_at timestamptz;
alter table public.inventory_items add column reserved_website_order_id uuid references private.website_orders(id) on delete restrict;
alter table public.inventory_items add constraint website_phone_reservation_status check(reserved_website_order_id is null or status='reserved');
alter table public.accessories add column website_reserved_quantity integer not null default 0;
alter table public.accessories add constraint website_accessory_reservation_quantity check(website_reserved_quantity>=0 and quantity>=website_reserved_quantity);
create table private.website_reservations(order_id uuid not null references private.website_orders(id) on delete restrict,inventory_item_id uuid references public.inventory_items(id) on delete restrict,accessory_id uuid references public.accessories(id) on delete restrict,quantity integer not null check(quantity>0),check(num_nonnulls(inventory_item_id,accessory_id)=1),check(inventory_item_id is null or quantity=1));
create unique index website_phone_reservation_unique on private.website_reservations(inventory_item_id) where inventory_item_id is not null;
create unique index website_accessory_reservation_unique on private.website_reservations(order_id,accessory_id) where accessory_id is not null;
create index website_reservations_order_idx on private.website_reservations(order_id);
create table private.website_order_events(id uuid primary key default gen_random_uuid(),order_id uuid not null references private.website_orders(id),from_status text not null,to_status text not null,actor uuid,created_at timestamptz not null default now());
create index website_order_events_order_idx on private.website_order_events(order_id,created_at);
alter table private.website_reservations enable row level security;
alter table private.website_order_events enable row level security;
revoke all on private.website_reservations,private.website_order_events from public,anon,authenticated;
create policy no_direct_access on private.website_reservations for all to anon,authenticated using(false) with check(false);
create policy no_direct_access on private.website_order_events for all to anon,authenticated using(false) with check(false);
create or replace function private.website_fulfil_order(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare o private.website_orders; s text:=p->>'status'; line jsonb; phone public.inventory_items; accessory public.accessories; customer uuid; sale uuid; item_id uuid; actor uuid; qty integer; cost numeric:=0; total numeric:=0; v_mobile text;
begin
 if auth.uid() is null or not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 select * into o from private.website_orders where id=(p->>'id')::uuid for update;
 if not found then raise exception 'Order not found'; end if;
 if s is null or s not in ('pending','confirmed','dispatched','completed','cancelled','return_pending') then raise exception 'Invalid order status'; end if;
 if o.status=s and (s not in ('confirmed','dispatched') or o.reserved_at is not null) then return jsonb_build_object('id',o.id,'sale_id',o.sale_id,'ok',true); end if;
 if not ((o.status='pending' and s in ('confirmed','cancelled')) or (o.status='confirmed' and s in ('dispatched','completed','cancelled')) or (o.status='dispatched' and s in ('completed','return_pending')) or (o.status='return_pending' and s='cancelled' and coalesce((p->>'stock_received')::boolean,false)) or (o.status=s and s in ('confirmed','dispatched') and o.reserved_at is null)) then raise exception 'This order cannot move to that status'; end if;
 if s='dispatched' and o.fulfilment<>'delivery' then raise exception 'Collection orders do not need dispatch'; end if;
 if length(coalesce(p->>'courier',''))>100 or length(coalesce(p->>'tracking_number',''))>120 then raise exception 'Courier or tracking number too long'; end if;
 if s='dispatched' and (nullif(trim(p->>'courier'),'') is null or nullif(trim(p->>'tracking_number'),'') is null) then raise exception 'Enter courier and tracking number before dispatch'; end if;
 if s in ('confirmed','dispatched','completed') then
  -- Same lock order as ERP sales: phones first, then accessories. No partial sale on failure.
  for line in select value from jsonb_array_elements(o.items) order by case when value->>'kind'='iphone' then 0 else 1 end,value->>'id' loop
   qty:=(line->>'quantity')::integer;
   if qty is null or qty<1 or (line->>'price')::numeric<=0 then raise exception 'Invalid order item'; end if;
   if line->>'kind'='iphone' then
    select * into phone from public.inventory_items where id=(line->>'id')::uuid for update;
    if not found or not (phone.status='in_stock' and phone.reserved_website_order_id is null or phone.status='reserved' and phone.reserved_website_order_id=o.id) or qty<>1 or exists(select 1 from public.sale_items where inventory_item_id=phone.id) then raise exception 'A phone is no longer available. Resolve stock before continuing'; end if;
    if s='completed' and phone.purchase_cost_pending then raise exception 'Owner must complete the phone purchase record in ERP first'; end if;
   elsif line->>'kind'='accessory' then
    select * into accessory from public.accessories where id=(line->>'id')::uuid for update;
    if not found or accessory.quantity-accessory.website_reserved_quantity+coalesce((select r.quantity from private.website_reservations r where r.order_id=o.id and r.accessory_id=accessory.id),0)<qty then raise exception 'Insufficient accessory stock'; end if;
   else raise exception 'Unsupported order item'; end if;
   total:=total+(line->>'price')::numeric*qty;
  end loop;
  if total<>o.total then raise exception 'Order total needs reconciliation'; end if;
  if o.reserved_at is null then
   for line in select value from jsonb_array_elements(o.items) order by case when value->>'kind'='iphone' then 0 else 1 end,value->>'id' loop
    qty:=(line->>'quantity')::integer;
    if line->>'kind'='iphone' then
     insert into private.website_reservations(order_id,inventory_item_id,quantity) values(o.id,(line->>'id')::uuid,1);
     update public.inventory_items set status='reserved',reserved_website_order_id=o.id where id=(line->>'id')::uuid;
    else
     insert into private.website_reservations(order_id,accessory_id,quantity) values(o.id,(line->>'id')::uuid,qty);
     update public.accessories set website_reserved_quantity=website_reserved_quantity+qty where id=(line->>'id')::uuid;
    end if;
   end loop;
   update private.website_orders set reserved_at=now() where id=o.id;
  end if;
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
    update public.inventory_items set status='sold',reserved_website_order_id=null,sold_at=now(),website_order_id=o.id,public_notes=concat_ws(E'\n',nullif(public_notes,''),'Sold through website · '||upper(substr(o.id::text,1,8))) where id=phone.id;
    insert into public.stock_movements(inventory_item_id,movement_type,from_status,to_status,reference_type,reference_id,notes,created_by) values(phone.id,'sale','reserved','sold','sale',sale,'Sold through website',actor);
   else
    select * into accessory from public.accessories where id=(line->>'id')::uuid;
    insert into public.sale_items(sale_id,accessory_id,item_name,quantity,unit_price,final_price) values(sale,accessory.id,line->>'title',qty,(line->>'price')::numeric,(line->>'price')::numeric*qty) returning id into item_id;
    insert into public.sale_item_costs(sale_item_id,cost_price_snapshot) values(item_id,accessory.purchase_price*qty);
    cost:=cost+accessory.purchase_price*qty;
    update public.accessories set quantity=quantity-qty,website_reserved_quantity=website_reserved_quantity-qty,updated_at=now() where id=accessory.id;
   end if;
  end loop;
  perform private.erp_post('sale',sale,'Sold through website',jsonb_build_array(jsonb_build_object('account','1100','debit',o.total),jsonb_build_object('account','4000','credit',o.total),jsonb_build_object('account','5000','debit',cost),jsonb_build_object('account','1200','credit',cost)));
 end if;

 if s='cancelled' and o.reserved_at is not null then
  -- Release only this order's reservation; dispatched parcels must return first.
  for line in select to_jsonb(r) from private.website_reservations r where r.order_id=o.id order by case when r.inventory_item_id is not null then 0 else 1 end,coalesce(r.inventory_item_id,r.accessory_id) loop
   if line->>'inventory_item_id' is not null then
    update public.inventory_items set status='in_stock',reserved_website_order_id=null where id=(line->>'inventory_item_id')::uuid and reserved_website_order_id=o.id;
   else
    update public.accessories set website_reserved_quantity=website_reserved_quantity-(line->>'quantity')::integer where id=(line->>'accessory_id')::uuid;
   end if;
  end loop;
 end if;
 if s in ('completed','cancelled') then delete from private.website_reservations where order_id=o.id; end if;
 insert into private.website_order_events(order_id,from_status,to_status,actor) values(o.id,o.status,s,auth.uid());
 update private.website_orders set status=s,updated_at=now(),confirmed_at=case when s='confirmed' then now() else confirmed_at end,dispatched_at=case when s='dispatched' then now() else dispatched_at end,completed_at=case when s='completed' then now() else completed_at end,cancelled_at=case when s='cancelled' then now() else cancelled_at end,courier=coalesce(nullif(trim(p->>'courier'),''),courier),tracking_number=coalesce(nullif(trim(p->>'tracking_number'),''),tracking_number),sale_id=coalesce(sale,sale_id) where id=o.id;
 return jsonb_build_object('id',o.id,'sale_id',sale,'ok',true);
end; $$;

do $$ declare src text; begin
 select pg_get_functiondef('private.website_products(boolean)'::regprocedure) into src;
 src:=replace(src,'greatest(a.quantity,0)','greatest(a.quantity-a.website_reserved_quantity,0)');
 src:=replace(src,'a.quantity>0','a.quantity>a.website_reserved_quantity');
 execute src;
 select pg_get_functiondef('private.website_order_list(text,integer)'::regprocedure) into src;
 src:=replace(src,'''pending'',''confirmed'',''dispatched''','''pending'',''confirmed'',''dispatched'',''return_pending''');
 src:=replace(src,'o.sale_id,s.invoice_number','o.sale_id,o.reserved_at,(select coalesce(jsonb_agg(jsonb_build_object(''status'',e.to_status,''at'',e.created_at) order by e.created_at),''[]''::jsonb) from private.website_order_events e where e.order_id=o.id) as history,s.invoice_number');
 execute src;
end $$;

-- Respect the same reservations when selling accessories in the ERP.
do $$ declare src text; begin
 select pg_get_functiondef('private.erp_action(jsonb)'::regprocedure) into src;
 src:=replace(src,'stock.quantity<extra_qty','stock.quantity-stock.website_reserved_quantity<extra_qty');
 src:=replace(src,'Insufficient accessory stock','Insufficient available accessory stock; some units may be reserved for website orders');
 execute src;
end $$;
