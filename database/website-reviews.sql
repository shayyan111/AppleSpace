-- Additive migration already applied to the shared Supabase project.
-- Existing inventory and ERP permissions are reused, not replaced.
create table if not exists private.website_reviews(id uuid primary key default gen_random_uuid(),name text not null check(length(name) between 2 and 100),product text not null check(length(product) between 2 and 160),rating integer not null check(rating between 1 and 5),body text not null check(length(body) between 10 and 2000),published boolean not null default false,consent boolean not null default false,created_at timestamptz not null default now());
alter table private.website_reviews enable row level security;
revoke all on private.website_reviews from public,anon,authenticated;
CREATE OR REPLACE FUNCTION private.website_review_update(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v uuid;
begin
 if not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 if coalesce((p->>'published')::boolean,false) and not coalesce((p->>'consent')::boolean,false) then raise exception 'Customer permission is required'; end if;
 if p->>'action'='delete' then delete from private.website_reviews where id=(p->>'id')::uuid returning id into v;
 else
 insert into private.website_reviews(id,name,product,rating,body,published,consent)
 values(coalesce(nullif(p->>'id','')::uuid,gen_random_uuid()),trim(p->>'name'),trim(p->>'product'),(p->>'rating')::integer,trim(p->>'body'),coalesce((p->>'published')::boolean,false),coalesce((p->>'consent')::boolean,false))
 on conflict(id) do update set name=excluded.name,product=excluded.product,rating=excluded.rating,body=excluded.body,published=excluded.published,consent=excluded.consent returning id into v;
 end if;
 return jsonb_build_object('id',v,'ok',true);
end;$function$
;

CREATE OR REPLACE FUNCTION public.store_review_update(p jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select private.website_review_update(p);$function$
;

CREATE OR REPLACE FUNCTION private.website_reviews_list(manage boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if manage and not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from private.website_reviews r where manage or (r.published and r.consent)),'[]'::jsonb);
end;$function$
;

CREATE OR REPLACE FUNCTION public.store_reviews(manage boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select private.website_reviews_list(manage);$function$
;

revoke all on function private.website_reviews_list(boolean),public.store_reviews(boolean) from public;
grant execute on function private.website_reviews_list(boolean),public.store_reviews(boolean) to anon,authenticated;
revoke all on function private.website_review_update(jsonb),public.store_review_update(jsonb) from public;
grant execute on function private.website_review_update(jsonb),public.store_review_update(jsonb) to authenticated;
notify pgrst,'reload schema';
