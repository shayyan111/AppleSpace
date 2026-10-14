begin;
insert into auth.users(id) values('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000002');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
do $$ declare d jsonb; p jsonb; o jsonb; begin
 d:=public.store_customer('{"action":"profile","name":"Verification Customer","phone":"03000000000","address":"Test address only"}');
 if d#>>'{profile,name}'<>'Verification Customer' then raise exception 'Profile save failed'; end if;
 select x into p from jsonb_array_elements(public.store_catalog()) x where x->>'kind'<>'on_demand' limit 1;
 if p is not null then
  d:=public.store_customer(jsonb_build_object('action','save','product_id',p->>'id'));
  if jsonb_array_length(d->'saved')<>1 then raise exception 'Wishlist save failed'; end if;
  o:=public.store_checkout(jsonb_build_object('request_id',gen_random_uuid(),'name','Verification Customer','phone','03000000000','fulfilment','pickup','items',jsonb_build_array(jsonb_build_object('id',p->>'id','kind',p->>'kind','price',p->'price','quantity',1))));
  d:=public.store_customer();
  if jsonb_array_length(d->'orders')<>1 or d#>>'{orders,0,id}'<>o->>'id' then raise exception 'Order ownership failed'; end if;
 end if;
 begin perform public.erp_delete_accessory('00000000-0000-4000-8000-000000000000');raise exception 'Staff isolation failed';exception when others then if SQLERRM<>'Active staff account required' then raise;end if;end;
 begin perform private.website_products(true);raise exception 'Manager isolation failed';exception when insufficient_privilege then null;end;
end $$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
do $$ declare d jsonb;begin d:=public.store_customer();if d->'profile'<>'{}'::jsonb or d->'saved'<>'[]'::jsonb or d->'orders'<>'[]'::jsonb then raise exception 'Cross-customer data leak';end if;end $$;
reset role;
select set_config('request.jwt.claim.sub','',true);
set local role anon;
do $$ begin begin perform public.store_customer();raise exception 'Guest access should fail';exception when insufficient_privilege then null;end;end $$;
reset role;
rollback;
select 'Customer profile, wishlist, checkout ownership, cross-account isolation, staff denial and guest denial passed; all test data rolled back' as result;
