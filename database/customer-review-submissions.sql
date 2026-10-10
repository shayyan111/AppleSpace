alter table private.website_reviews add column if not exists contact_phone text;
alter table private.website_reviews add column if not exists request_id uuid unique;
alter table private.website_reviews add column if not exists published_at timestamptz;
alter table private.website_reviews add column if not exists moderation_status text not null default 'pending' check(moderation_status in ('pending','published','rejected'));
update private.website_reviews set moderation_status='published',published_at=coalesce(published_at,created_at) where published;
create index if not exists website_reviews_contact_created_idx on private.website_reviews(contact_phone,created_at desc);
create or replace function private.website_reviews_list(manage boolean default false) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if manage and not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 if manage then
  return coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from private.website_reviews r),'[]'::jsonb);
 end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'product',r.product,'rating',r.rating,'body',r.body,'published_at',r.published_at) order by r.published_at desc) from private.website_reviews r where r.published and r.consent and r.moderation_status='published'),'[]'::jsonb);
end;$$;
create or replace function private.website_review_submit(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v uuid; phone text; req uuid; existing private.website_reviews%rowtype;
begin
 if coalesce(p->>'website','')<>'' then raise exception 'Unable to submit this review'; end if;
 if not coalesce((p->>'consent')::boolean,false) then raise exception 'Please agree to publication of your review'; end if;
 phone:=regexp_replace(coalesce(p->>'phone',''),'[^0-9]','','g');
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
 insert into private.website_reviews(name,product,rating,body,consent,published,contact_phone,request_id,moderation_status)
 values(trim(p->>'name'),trim(p->>'product'),(p->>'rating')::integer,trim(p->>'body'),true,false,phone,req,'pending') returning id into v;
 return jsonb_build_object('id',v,'status','pending');
end;$$;
revoke all on function private.website_review_submit(jsonb) from public;
grant execute on function private.website_review_submit(jsonb) to anon,authenticated;
create or replace function public.store_review_submit(p jsonb) returns jsonb language sql set search_path='' as $$select private.website_review_submit(p);$$;
revoke all on function public.store_review_submit(jsonb) from public;
grant execute on function public.store_review_submit(jsonb) to anon,authenticated;
create or replace function private.website_review_update(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v uuid;
begin
 if not coalesce(private.website_can_manage(),false) then raise exception 'Website access required' using errcode='42501'; end if;
 if p->>'action'='delete' then
  delete from private.website_reviews where id=(p->>'id')::uuid returning id into v;
 elsif p->>'action' in ('approve','reject','unpublish') then
  update private.website_reviews set published=p->>'action'='approve',moderation_status=case p->>'action' when 'approve' then 'published' when 'reject' then 'rejected' else 'pending' end,
  published_at=case when p->>'action'='approve' then case when published then coalesce(published_at,now()) else now() end else null end
  where id=(p->>'id')::uuid and (p->>'action'<>'approve' or consent) returning id into v;
  if v is null then raise exception 'Review not found or customer permission is missing'; end if;
 else
  if coalesce((p->>'published')::boolean,false) and not coalesce((p->>'consent')::boolean,false) then raise exception 'Customer permission is required'; end if;
  insert into private.website_reviews(id,name,product,rating,body,published,consent,moderation_status,published_at)
  values(coalesce(nullif(p->>'id','')::uuid,gen_random_uuid()),trim(p->>'name'),trim(p->>'product'),(p->>'rating')::integer,trim(p->>'body'),coalesce((p->>'published')::boolean,false),coalesce((p->>'consent')::boolean,false),case when (p->>'published')::boolean then 'published' else 'pending' end,case when (p->>'published')::boolean then now() else null end)
  on conflict(id) do update set name=excluded.name,product=excluded.product,rating=excluded.rating,body=excluded.body,published=excluded.published,consent=excluded.consent,moderation_status=excluded.moderation_status,
  published_at=case when excluded.published then case when private.website_reviews.published then coalesce(private.website_reviews.published_at,now()) else now() end else null end returning id into v;
 end if;
 return jsonb_build_object('id',v,'ok',true);
end;$$;
revoke all on function private.website_review_update(jsonb) from public;
grant execute on function private.website_review_update(jsonb) to authenticated;
notify pgrst,'reload schema';
