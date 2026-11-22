-- Sathvika M V Store migration v3. Run once (or re-run safely) in Supabase SQL Editor.
-- Additive migration for the existing v2 store. Does not seed products or demo records.

-- Phase 1: traceable stock imports and expired-stock removal history.
create table if not exists public.stock_imports (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references auth.users(id) on delete restrict,
  file_name text not null,
  file_size bigint not null default 0,
  row_count integer not null default 0,
  content_hash text not null,
  rows_hash text not null,
  status text not null default 'processing' check (status in ('processing','complete','undone')),
  summary jsonb not null default '{}'::jsonb,
  undo_details jsonb not null default '{"previous_batches":[]}'::jsonb,
  created_at timestamptz not null default now(),
  undone_at timestamptz
);
create index if not exists stock_imports_hash_idx on public.stock_imports(content_hash, rows_hash, created_at desc);
create table if not exists public.expired_stock_removals (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid,
  product_id uuid,
  barcode text,
  product_name text not null,
  expiry_date date,
  units numeric(12,3) not null,
  cost_price numeric(12,2),
  mrp numeric(12,2),
  removed_by uuid references auth.users(id) on delete set null,
  removed_at timestamptz not null default now()
);
alter table public.products add column if not exists created_import_id uuid references public.stock_imports(id) on delete set null;
alter table public.batches add column if not exists import_id uuid references public.stock_imports(id) on delete set null;
create index if not exists batches_import_id_idx on public.batches(import_id) where import_id is not null;

alter table public.stock_imports enable row level security;
alter table public.expired_stock_removals enable row level security;
drop policy if exists stock_imports_owner_select on public.stock_imports;
create policy stock_imports_owner_select on public.stock_imports for select to authenticated using (public.is_store_user());
drop policy if exists stock_imports_owner_insert on public.stock_imports;
create policy stock_imports_owner_insert on public.stock_imports for insert to authenticated with check (public.is_store_user() and created_by=auth.uid());
drop policy if exists stock_imports_owner_update on public.stock_imports;
create policy stock_imports_owner_update on public.stock_imports for update to authenticated using (public.is_store_owner() or (created_by=auth.uid() and public.is_store_user())) with check (public.is_store_owner() or (created_by=auth.uid() and public.is_store_user()));
drop policy if exists expired_stock_owner_select on public.expired_stock_removals;
create policy expired_stock_owner_select on public.expired_stock_removals for select to authenticated using (public.is_store_owner());
drop policy if exists expired_stock_owner_insert on public.expired_stock_removals;
create policy expired_stock_owner_insert on public.expired_stock_removals for insert to authenticated with check (public.is_store_owner() and removed_by=auth.uid());
grant select, insert, update on public.stock_imports to authenticated;
grant select, insert on public.expired_stock_removals to authenticated;

create or replace function public.undo_stock_import(p_import_id uuid) returns void
language plpgsql security definer set search_path=public
as $$
declare j public.stock_imports%rowtype; prior jsonb;
begin
  if not public.is_store_owner() then raise exception 'Owner access required'; end if;
  select * into j from public.stock_imports where id=p_import_id for update;
  if not found or j.status<>'complete' then raise exception 'Import not found or already undone'; end if;
  if now()>j.created_at+interval '10 minutes' then raise exception 'The 10-minute undo period has expired'; end if;
  update public.batches set units=0 where import_id=p_import_id and id in (select batch_id from public.sale_items where batch_id is not null);
  delete from public.batches where import_id=p_import_id and id not in (select batch_id from public.sale_items where batch_id is not null);
  for prior in select value from jsonb_array_elements(coalesce(j.undo_details->'previous_batches','[]'::jsonb)) loop
    update public.batches set units=(prior->>'units')::numeric where id=(prior->>'id')::uuid;
  end loop;
  delete from public.products p where p.created_import_id=p_import_id and not exists(select 1 from public.sale_items i where i.product_id=p.id) and not exists(select 1 from public.batches b where b.product_id=p.id);
  update public.stock_imports set status='undone',undone_at=now() where id=p_import_id;
end $$;
revoke all on function public.undo_stock_import(uuid) from public, anon;
grant execute on function public.undo_stock_import(uuid) to authenticated;

-- Phase 3: supplier purchases and payment ledger.
create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(), name text not null, phone text,
  created_at timestamptz not null default now()
);
create table if not exists public.purchases (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  bill_number text, bill_date date not null default current_date,
  total numeric(12,2) not null check(total>=0), remind_on date, note text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), canceled_at timestamptz
);
create table if not exists public.purchase_payments (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.purchases(id) on delete restrict,
  amount numeric(12,2) not null check(amount>0), paid_on date not null default current_date,
  mode text not null check(mode in ('cash','upi','bank')), note text,
  created_by uuid references auth.users(id) on delete set null, canceled_at timestamptz
);
alter table public.batches add column if not exists purchase_id uuid references public.purchases(id) on delete set null;
alter table public.batches add column if not exists cost_price numeric(12,2) check(cost_price is null or cost_price>=0);
create index if not exists purchases_supplier_date_idx on public.purchases(supplier_id,bill_date desc);
create index if not exists purchase_payments_purchase_idx on public.purchase_payments(purchase_id) where canceled_at is null;

-- Phase 4: customer identities and credit payment ledger.
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(), name text not null,
  phone text not null unique, created_at timestamptz not null default now()
);
create table if not exists public.customer_payments (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  sale_id uuid references public.sales(id) on delete set null,
  amount numeric(12,2) not null check(amount>0), paid_on date not null default current_date,
  mode text not null check(mode in ('cash','upi')), note text,
  created_by uuid references auth.users(id) on delete set null, canceled_at timestamptz
);
alter table public.sales add column if not exists customer_id uuid references public.customers(id) on delete set null;
alter type public.payment_mode add value if not exists 'credit';
create index if not exists customer_payments_customer_idx on public.customer_payments(customer_id,paid_on desc) where canceled_at is null;

-- Explicit table grants are required in addition to policies.
revoke all on public.suppliers,public.purchases,public.purchase_payments,public.customers,public.customer_payments from anon, public;
grant select,insert,update,delete on public.suppliers,public.purchases,public.purchase_payments to authenticated;
grant insert,update,delete on public.customers to authenticated;
revoke select on public.customers from authenticated;
grant select(id,name,phone) on public.customers to authenticated;
grant select,insert,update,delete on public.customer_payments to authenticated;
alter table public.suppliers enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_payments enable row level security;
alter table public.customers enable row level security;
alter table public.customer_payments enable row level security;
drop policy if exists suppliers_owner_all on public.suppliers;
create policy suppliers_owner_all on public.suppliers for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists purchases_owner_all on public.purchases;
create policy purchases_owner_all on public.purchases for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists purchase_payments_owner_all on public.purchase_payments;
create policy purchase_payments_owner_all on public.purchase_payments for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists customers_identity_read on public.customers;
create policy customers_identity_read on public.customers for select to authenticated using(public.is_store_user());
drop policy if exists customers_staff_add on public.customers;
create policy customers_staff_add on public.customers for insert to authenticated with check(public.is_store_user());
drop policy if exists customers_owner_update on public.customers;
create policy customers_owner_update on public.customers for update to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists customers_owner_delete on public.customers;
create policy customers_owner_delete on public.customers for delete to authenticated using(public.is_store_owner());
drop policy if exists customer_payments_owner_all on public.customer_payments;
create policy customer_payments_owner_all on public.customer_payments for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner());

create or replace function public.owner_customer_records() returns table(id uuid,name text,phone text,created_at timestamptz)
language sql stable security definer set search_path=public
as $$ select c.id,c.name,c.phone,c.created_at from public.customers c where public.is_store_owner() order by c.name $$;
revoke all on function public.owner_customer_records() from public, anon;
grant execute on function public.owner_customer_records() to authenticated;

-- Replace v2 billing functions. Existing FEFO/cancellation behavior is retained.
drop function if exists public.create_sale(jsonb,public.payment_mode,numeric,text,text);
create or replace function public.create_sale(
  p_items jsonb,p_payment public.payment_mode,p_discount numeric default 0,
  p_customer_name text default null,p_customer_phone text default null,
  p_customer_id uuid default null,p_paid_now numeric default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare v_sale uuid; v_subtotal numeric(12,2):=0; v_discount numeric(12,2):=coalesce(p_discount,0);
  v_paid numeric(12,2):=coalesce(p_paid_now,0); v_item jsonb; v_pid uuid; v_qty numeric;
  v_price numeric; v_cost numeric; v_left numeric; v_batch record; v_take numeric(12,3);
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
    select mrp,cost_price into v_price,v_cost from public.products where id=v_pid for update;
    if not found then raise exception 'Product not found'; end if;
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
    v_pid:=(v_item->>'product_id')::uuid;v_qty:=(v_item->>'quantity')::numeric;v_left:=v_qty;
    select mrp,cost_price into v_price,v_cost from public.products where id=v_pid;
    for v_batch in select id,units,cost_price from public.batches where product_id=v_pid and units>0 and (expiry_date is null or expiry_date>=current_date) order by expiry_date nulls last,created_at for update loop
      exit when v_left<=0; v_take:=least(v_left,v_batch.units);
      update public.batches set units=units-v_take where id=v_batch.id;
      insert into public.sale_items(sale_id,product_id,batch_id,quantity,price,cost_price)
      values(v_sale,v_pid,v_batch.id,v_take,v_price,coalesce(v_batch.cost_price,v_cost));
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
revoke all on function public.create_sale(jsonb,public.payment_mode,numeric,text,text,uuid,numeric) from public, anon;
grant execute on function public.create_sale(jsonb,public.payment_mode,numeric,text,text,uuid,numeric) to authenticated;

create or replace function public.cancel_sale(p_sale_id uuid) returns void
language plpgsql security definer set search_path=public
as $$ begin
  if not public.is_store_owner() then raise exception 'Owner access required'; end if;
  perform 1 from public.sales where id=p_sale_id and canceled_at is null for update;
  if not found then raise exception 'Bill not found or already cancelled'; end if;
  update public.batches b set units=b.units+i.quantity from public.sale_items i
    where i.sale_id=p_sale_id and i.batch_id=b.id;
  update public.sales set canceled_at=now() where id=p_sale_id;
end $$;
revoke all on function public.cancel_sale(uuid) from public, anon;
grant execute on function public.cancel_sale(uuid) to authenticated;

-- Owner-controlled staff activation avoids needing an Edge Function for deactivation.
create or replace function public.set_staff_active(p_staff_id uuid,p_active boolean) returns void
language plpgsql security definer set search_path=public
as $$ begin
  if not public.is_store_owner() then raise exception 'Owner access required'; end if;
  update public.profiles set active=p_active where id=p_staff_id and role='staff';
  if not found then raise exception 'Staff account not found'; end if;
end $$;
revoke all on function public.set_staff_active(uuid,boolean) from public, anon;
grant execute on function public.set_staff_active(uuid,boolean) to authenticated;

-- Staff may add stock only without owner-only purchase or cost data.
drop policy if exists batches_add_stock on public.batches;
create policy batches_add_stock on public.batches for insert to authenticated
with check (public.is_store_user() and (public.is_store_owner() or (cost_price is null and purchase_id is null)));
drop policy if exists "signed-in users add batches" on public.batches;
