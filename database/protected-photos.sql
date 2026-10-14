-- Public catalog gets opaque media identifiers; staff can still manage originals.
do $patch$ declare src text; begin
 select pg_get_functiondef('private.website_products(boolean)'::regprocedure) into src;
 src:=replace(src,'''path'',m.object_path','''path'',case when manage then m.object_path else m.id::text end');
 execute src;
end $patch$;
create function private.website_photo(ref text) returns text language plpgsql stable security definer set search_path='' as $$
declare path text;
begin
 if coalesce(private.website_can_manage(),false) then
  select object_path into path from private.website_media where id::text=ref or object_path=ref limit 1;
 else
  select m.object_path into path from private.website_media m
  where m.id::text=ref and exists(select 1 from jsonb_array_elements(private.website_products(false)) p cross join lateral jsonb_array_elements(p->'images') i where i->>'id'=m.id::text);
 end if;
 return path;
end $$;
revoke all on function private.website_photo(text) from public;
grant execute on function private.website_photo(text) to anon,authenticated;
create function public.store_photo(ref text) returns text language sql security invoker set search_path='' as $$select private.website_photo(ref)$$;
revoke all on function public.store_photo(text) from public;
grant execute on function public.store_photo(text) to anon,authenticated;
-- Set bucket private only AFTER the updated storefront and photo service deploy.
