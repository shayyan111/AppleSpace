-- Optional genuine previous price, never used to calculate checkout totals.
alter table public.inventory_items add column website_compare_at_price numeric(12,2) check(website_compare_at_price>0);
alter table private.website_accessory_content add column compare_at_price numeric(12,2) check(compare_at_price>0);
alter table private.website_on_demand add column compare_at_price numeric(12,2) check(compare_at_price>0);
do $patch$ declare src text; begin
 select pg_get_functiondef('private.website_products(boolean)'::regprocedure) into src;
 src:=replace(src,'''condition'',i.condition_grade,''price''','''compare_at_price'',i.website_compare_at_price,''condition'',i.condition_grade,''price''');
 src:=replace(src,'''price'',coalesce(w.price,a.sale_price)','''compare_at_price'',w.compare_at_price,''price'',coalesce(w.price,a.sale_price)');
 src:=replace(src,'''price'',d.price,''price_label''','''compare_at_price'',d.compare_at_price,''price'',d.price,''price_label''');
 execute src;
 select pg_get_functiondef('private.website_update(jsonb)'::regprocedure) into src;
 src:=replace(src,'if a=''on_demand_save'' then',$insert$
 if a in ('listing','on_demand_save') and p ? 'compare_at_price' and nullif(p->>'compare_at_price','') is not null then
  if nullif(p->>'price','') is null or (p->>'price')::numeric<=0 or (p->>'compare_at_price')::numeric<=(p->>'price')::numeric or (p->>'compare_at_price')::numeric in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric) then raise exception 'Original price must be higher than the selling price. Leave it blank for no discount'; end if;
 end if;
 if a='on_demand_save' then$insert$);
 src:=replace(src,'return jsonb_build_object(''id'',v,''ok'',true);',$insert$
 if a in ('listing','on_demand_save') and p ? 'compare_at_price' then
  if a='on_demand_save' then update private.website_on_demand set compare_at_price=nullif(p->>'compare_at_price','')::numeric where id=v;
  elsif p->>'kind'='iphone' then update public.inventory_items set website_compare_at_price=nullif(p->>'compare_at_price','')::numeric where id=v;
  elsif p->>'kind'='accessory' then update private.website_accessory_content set compare_at_price=nullif(p->>'compare_at_price','')::numeric where accessory_id=v;
  end if;
 end if;
 return jsonb_build_object('id',v,'ok',true);$insert$);
 execute src;
end $patch$;
