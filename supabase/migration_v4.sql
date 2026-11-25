-- Sathvika M V store v4 — additive, safe for existing v3 deployments.
-- Adds two product prices, product/batch audit tables, hidden products, and strict owner-only edits.

alter table public.products add column if not exists selling_price numeric(12,2);
update public.products set selling_price=mrp where selling_price is null;
alter table public.products add column if not exists mrp_confirmed boolean not null default false;
alter table public.products add column if not exists hidden boolean not null default false;
alter table public.batches add column if not exists deleted_at timestamptz;

alter table public.products alter column selling_price set default null;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.products'::regclass and conname='products_selling_price_not_above_mrp') then
    alter table public.products add constraint products_selling_price_not_above_mrp
      check(selling_price is null or (selling_price>=0 and selling_price<=mrp));
  end if;
end $$;

-- Snapshot the printed pack price at sale time; sale_items.price remains the charged price.
alter table public.sale_items add column if not exists mrp numeric(12,2);
update public.sale_items i set mrp=p.mrp from public.products p where p.id=i.product_id and i.mrp is null;

create table if not exists public.product_changes (
  id uuid primary key default gen_random_uuid(), product_id uuid not null,
  product_name text not null, changed_by uuid references auth.users(id) on delete set null,
  field_name text not null, old_value text, new_value text,
  created_at timestamptz not null default now()
);
create index if not exists product_changes_product_created_idx on public.product_changes(product_id,created_at desc);

-- No batch FK is used so delete records survive batch deletion.
create table if not exists public.stock_adjustments (
  id uuid primary key default gen_random_uuid(), batch_id uuid, product_id uuid,
  product_name text not null, batch_mfg_date date, batch_expiry_date date,
  units_before numeric(12,3), delta numeric(12,3) not null,
  reason text not null, who uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists stock_adjustments_product_created_idx on public.stock_adjustments(product_id,created_at desc);

revoke all on public.product_changes,public.stock_adjustments from anon,public;
grant select,insert,update,delete on public.product_changes,public.stock_adjustments to authenticated;
alter table public.product_changes enable row level security;
alter table public.stock_adjustments enable row level security;
drop policy if exists product_changes_owner_all on public.product_changes;
create policy product_changes_owner_all on public.product_changes for all to authenticated
  using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists stock_adjustments_owner_all on public.stock_adjustments;
create policy stock_adjustments_owner_all on public.stock_adjustments for all to authenticated
  using(public.is_store_owner()) with check(public.is_store_owner());

-- Remove every non-read product/batch policy except the intended rules, so an old permissive policy cannot OR-bypass owner-only writes.
do $$ declare pol record; begin
  for pol in select schemaname,tablename,policyname from pg_policies
    where schemaname='public' and tablename in ('products','batches')
      and cmd in ('INSERT','UPDATE','DELETE','ALL')
      and policyname not in ('products_owner_insert','products_owner_update','products_owner_delete','batches_add_stock','batches_owner_update','batches_owner_delete')
  loop execute format('drop policy %I on %I.%I',pol.policyname,pol.schemaname,pol.tablename); end loop;
end $$;
-- Remove any legacy permissive write policies before installing owner-only product/batch rules.
alter table public.products enable row level security;
alter table public.batches enable row level security;
drop policy if exists "signed-in users add products" on public.products;
drop policy if exists "owners update products" on public.products;
drop policy if exists "owners delete products" on public.products;
drop policy if exists "signed-in users update products" on public.products;
drop policy if exists "signed-in users delete products" on public.products;
drop policy if exists products_update on public.products;
drop policy if exists products_insert on public.products;
drop policy if exists products_delete on public.products;
drop policy if exists products_owner_insert on public.products;
drop policy if exists products_owner_update on public.products;
drop policy if exists products_owner_delete on public.products;
create policy products_owner_insert on public.products for insert to authenticated with check(public.is_store_owner());
create policy products_owner_update on public.products for update to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
create policy products_owner_delete on public.products for delete to authenticated using(public.is_store_owner());
drop policy if exists batches_add_stock on public.batches;
create policy batches_add_stock on public.batches for insert to authenticated with check(public.is_store_user() and (public.is_store_owner() or (cost_price is null and purchase_id is null)));

drop policy if exists "owners correct batches" on public.batches;
drop policy if exists "owners delete batches" on public.batches;
drop policy if exists "signed-in users update batches" on public.batches;
drop policy if exists "signed-in users delete batches" on public.batches;
drop policy if exists batches_update on public.batches;
drop policy if exists batches_delete on public.batches;
drop policy if exists batches_owner_update on public.batches;
drop policy if exists batches_owner_delete on public.batches;
create policy batches_owner_update on public.batches for update to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
create policy batches_owner_delete on public.batches for delete to authenticated using(public.is_store_owner());

-- Preserve old sale rows and allow an owner to remove a batch without deleting bill history.
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.sale_items'::regclass and conname='sale_items_batch_id_fkey' and confdeltype='n') then
    alter table public.sale_items drop constraint if exists sale_items_batch_id_fkey;
    alter table public.sale_items add constraint sale_items_batch_id_fkey
      foreign key(batch_id) references public.batches(id) on delete set null;
  end if;
end $$;

create or replace function public.create_sale(
  p_items jsonb,p_payment public.payment_mode,p_discount numeric default 0,
  p_customer_name text default null,p_customer_phone text default null,
  p_customer_id uuid default null,p_paid_now numeric default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare v_sale uuid; v_subtotal numeric(12,2):=0; v_discount numeric(12,2):=coalesce(p_discount,0);
  v_paid numeric(12,2):=coalesce(p_paid_now,0); v_item jsonb; v_pid uuid; v_qty numeric;
  v_price numeric; v_mrp numeric; v_cost numeric; v_hidden boolean; v_left numeric; v_batch record; v_take numeric(12,3);
  v_customer public.customers%rowtype;
begin
  if auth.uid() is null or not public.is_store_user() then raise exception 'Sign in to create a bill'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item'; end if;
  if p_payment::text='credit' then
    if p_customer_id is null then raise exception 'Choose a customer for a credit bill'; end if;
    select * into v_customer from public.customers where id=p_customer_id;
    if not found then raise exception 'Customer not found'; end if;
  elsif p_paid_now is not null then raise exception 'Paid-now amount is only valid for credit bills';
  end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_pid:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::numeric;
    if v_qty is null or v_qty<=0 then raise exception 'Quantity must be positive'; end if;
    select coalesce(selling_price,mrp),cost_price,mrp,hidden into v_price,v_cost,v_mrp,v_hidden from public.products where id=v_pid for update;
    if not found then raise exception 'Product not found'; end if;
    if v_hidden then raise exception 'This product is hidden and cannot be billed'; end if;
    if v_price>v_mrp then raise exception 'Selling price cannot be more than MRP'; end if;
    v_subtotal:=v_subtotal+v_price*v_qty;
  end loop;
  if v_discount<0 or v_discount>v_subtotal then raise exception 'Discount must be between zero and the bill subtotal'; end if;
  if p_payment::text='credit' and (v_paid<0 or v_paid>v_subtotal-v_discount) then raise exception 'Paid-now amount exceeds the credit bill balance'; end if;
  insert into public.sales(subtotal,discount,total,payment_mode,customer_name,customer_phone,customer_id,staff_id)
  values(v_subtotal,v_discount,v_subtotal-v_discount,p_payment,
    case when p_payment::text='credit' then v_customer.name else nullif(trim(p_customer_name),'') end,
    case when p_payment::text='credit' then v_customer.phone else nullif(trim(p_customer_phone),'') end,
    case when p_payment::text='credit' then p_customer_id else null end,auth.uid()) returning id into v_sale;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_pid:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::numeric; v_left:=v_qty;
    select coalesce(selling_price,mrp),cost_price,mrp,hidden into v_price,v_cost,v_mrp,v_hidden from public.products where id=v_pid;
    if v_hidden then raise exception 'This product is hidden and cannot be billed'; end if;
    for v_batch in select id,units,cost_price from public.batches where product_id=v_pid and units>0 and (expiry_date is null or expiry_date>=current_date) order by expiry_date nulls last,created_at for update loop
      exit when v_left<=0; v_take:=least(v_left,v_batch.units);
      update public.batches set units=units-v_take where id=v_batch.id;
      insert into public.sale_items(sale_id,product_id,batch_id,quantity,price,cost_price,mrp)
      values(v_sale,v_pid,v_batch.id,v_take,v_price,coalesce(v_batch.cost_price,v_cost),v_mrp);
      v_left:=v_left-v_take;
    end loop;
    if v_left>0 then raise exception 'Not enough unexpired stock for % (short by %)',(select name from public.products where id=v_pid),v_left; end if;
  end loop;
  if p_payment::text='credit' and v_paid>0 then
    insert into public.customer_payments(customer_id,sale_id,amount,paid_on,mode,created_by)
    values(p_customer_id,v_sale,v_paid,current_date,'cash',auth.uid());
  end if;
  return v_sale;
end $$;
revoke all on function public.create_sale(jsonb,public.payment_mode,numeric,text,text,uuid,numeric) from public,anon;
grant execute on function public.create_sale(jsonb,public.payment_mode,numeric,text,text,uuid,numeric) to authenticated;
