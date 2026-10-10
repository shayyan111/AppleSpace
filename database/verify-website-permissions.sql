-- Rollback-only: creates a temporary website account. Leaves no user, role or data changes.
begin;
insert into auth.users(id,email) values('d35518bd-cf0f-4fb0-9d67-af4cb16dd190','aspace-rollback-security-test@example.invalid');
insert into private.website_managers(user_id,active) values('d35518bd-cf0f-4fb0-9d67-af4cb16dd190',true);
set local role authenticated;
set local request.jwt.claim.sub='d35518bd-cf0f-4fb0-9d67-af4cb16dd190';
select jsonb_build_object('can_manage',private.website_can_manage(),'raw_inventory_rows',(select count(*) from public.inventory_items),'purchase_rows',(select count(*) from public.purchases),'owner',public.store_portal()->'owner','unsafe_fields',(public.store_portal()->'products')::text ~ '"(purchase_price|profit|imei_1|imei_2|supplier_id|purchase_id)"','portal_product_count',jsonb_array_length(public.store_portal()->'products')) test;
-- Expected: true, 0, 0, null/false, false, available unsold inventory count.
rollback;
