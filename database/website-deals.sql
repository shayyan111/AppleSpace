create table if not exists private.website_deals(
 product_id uuid primary key,
 kind text not null check(kind in ('iphone','on_demand')),
 updated_at timestamptz not null default now()
);
alter table private.website_deals enable row level security;
revoke all on private.website_deals from public,anon,authenticated;
create or replace function public.store_deals(manage boolean default false) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if manage and not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(p order by d.updated_at desc) from jsonb_array_elements(private.website_products(manage)) p join private.website_deals d on d.product_id=(p->>'id')::uuid and d.kind=p->>'kind'),'[]'::jsonb);
end;$$;
create or replace function public.store_deal_save(product_id uuid, enabled boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare item jsonb;
begin
 if not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 if enabled is null then raise exception 'Choose whether to publish the deal'; end if;
 if enabled then
  select p into item from jsonb_array_elements(private.website_products(true)) p where p->>'id'=product_id::text;
  if item is null or not ((item->>'kind'='iphone' and ((item->>'model')||' '||(item->>'title')) !~* 'ipad') or (item->>'kind'='on_demand' and item->>'category'='iphones')) then raise exception 'Choose an available phone'; end if;
  insert into private.website_deals(product_id,kind) values(product_id,item->>'kind') on conflict on constraint website_deals_pkey do update set kind=excluded.kind,updated_at=now();
 else
  delete from private.website_deals d where d.product_id=store_deal_save.product_id;
 end if;
 return jsonb_build_object('ok',true);
end;$$;
revoke all on function public.store_deals(boolean) from public;
grant execute on function public.store_deals(boolean) to anon,authenticated;
revoke all on function public.store_deal_save(uuid,boolean) from public,anon;
grant execute on function public.store_deal_save(uuid,boolean) to authenticated;

drop policy if exists website_deals_gateway_only on private.website_deals;
create policy website_deals_gateway_only on private.website_deals for all to anon,authenticated using(false) with check(false);
