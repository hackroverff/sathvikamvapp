-- Sathvika M V Store — final schema for a fresh Supabase project.
-- For an existing v2 database run supabase/migration_v3.sql instead.
-- No sample/demo store records are inserted by this schema.
create extension if not exists pgcrypto;

do $$ begin create type public.store_role as enum ('owner','staff'); exception when duplicate_object then null; end $$;
do $$ begin create type public.payment_mode as enum ('cash','upi','credit'); exception when duplicate_object then null; end $$;
do $$ begin create type public.unit_type as enum ('piece','kg','litre'); exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.store_role not null default 'staff',
  display_name text not null default '',
  email text unique,
  active boolean not null default false,
  created_at timestamptz not null default now()
);
create or replace function public.create_profile_for_user() returns trigger
language plpgsql security definer set search_path=public
as $$ begin
  insert into public.profiles(id,display_name,email,active)
  values(new.id,coalesce(new.raw_user_meta_data->>'name',split_part(new.email,'@',1)),new.email,false)
  on conflict(id) do nothing; return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.create_profile_for_user();

create or replace function public.owner_exists() returns boolean
language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where role='owner' and active) $$;
revoke all on function public.owner_exists() from public;
grant execute on function public.owner_exists() to anon,authenticated;
create or replace function public.claim_first_owner() returns void
language plpgsql security definer set search_path=public
as $$ begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  perform pg_advisory_xact_lock(73194210);
  if exists(select 1 from public.profiles where role='owner') then raise exception 'The store already has an owner'; end if;
  update public.profiles set role='owner',active=true where id=auth.uid();
  if not found then raise exception 'Profile was not created'; end if;
end $$;
revoke all on function public.claim_first_owner() from public,anon;
grant execute on function public.claim_first_owner() to authenticated;
create or replace function public.is_store_owner() returns boolean
language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='owner' and active) $$;
create or replace function public.is_store_user() returns boolean
language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role in ('owner','staff') and active) $$;
revoke all on function public.is_store_owner() from public,anon;
revoke all on function public.is_store_user() from public,anon;
grant execute on function public.is_store_owner(),public.is_store_user() to authenticated;

create table if not exists public.stock_imports (
  id uuid primary key default gen_random_uuid(), created_by uuid not null references auth.users(id) on delete restrict,
  file_name text not null, file_size bigint not null default 0, row_count integer not null default 0,
  content_hash text not null, rows_hash text not null,
  status text not null default 'processing' check(status in ('processing','complete','undone')),
  summary jsonb not null default '{}'::jsonb, undo_details jsonb not null default '{"previous_batches":[]}'::jsonb,
  created_at timestamptz not null default now(), undone_at timestamptz
);
create index if not exists stock_imports_hash_idx on public.stock_imports(content_hash,rows_hash,created_at desc);
create table if not exists public.expired_stock_removals (
  id uuid primary key default gen_random_uuid(), batch_id uuid, product_id uuid, barcode text,
  product_name text not null, expiry_date date, units numeric(12,3) not null,
  cost_price numeric(12,2), mrp numeric(12,2), removed_by uuid references auth.users(id) on delete set null,
  removed_at timestamptz not null default now()
);
create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(), name text not null, phone text,
  created_at timestamptz not null default now()
);
create table if not exists public.purchases (
  id uuid primary key default gen_random_uuid(), supplier_id uuid not null references public.suppliers(id) on delete restrict,
  bill_number text, bill_date date not null default current_date,
  total numeric(12,2) not null check(total>=0), remind_on date, note text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), canceled_at timestamptz
);
create table if not exists public.purchase_payments (
  id uuid primary key default gen_random_uuid(), purchase_id uuid not null references public.purchases(id) on delete restrict,
  amount numeric(12,2) not null check(amount>0), paid_on date not null default current_date,
  mode text not null check(mode in ('cash','upi','bank')), note text,
  created_by uuid references auth.users(id) on delete set null, canceled_at timestamptz
);
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(), name text not null, phone text not null unique,
  created_at timestamptz not null default now()
);
create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(), name text not null unique,
  created_at timestamptz not null default now()
);
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(), barcode text unique,
  name text not null, category text not null default 'General',
  mrp numeric(12,2) not null check(mrp>=0), selling_price numeric(12,2), mrp_confirmed boolean not null default false, hidden boolean not null default false, cost_price numeric(12,2) check(cost_price is null or cost_price>=0),
  check(selling_price is null or (selling_price>=0 and selling_price<=mrp)),
  unit_type public.unit_type not null default 'piece', low_stock_limit integer not null default 5 check(low_stock_limit>=0),
  created_import_id uuid references public.stock_imports(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.batches (
  id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id) on delete cascade,
  mfg_date date, expiry_date date, units numeric(12,3) not null check(units>=0),
  discounted boolean not null default false, client_op_id text unique,
  import_id uuid references public.stock_imports(id) on delete set null,
  purchase_id uuid references public.purchases(id) on delete set null, deleted_at timestamptz,
  cost_price numeric(12,2) check(cost_price is null or cost_price>=0),
  created_at timestamptz not null default now(),
  check(mfg_date is null or expiry_date is null or expiry_date>mfg_date)
);
create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(), bill_number bigint generated by default as identity unique,
  created_at timestamptz not null default now(), subtotal numeric(12,2) not null default 0 check(subtotal>=0),
  discount numeric(12,2) not null default 0 check(discount>=0), total numeric(12,2) not null check(total>=0),
  payment_mode public.payment_mode not null default 'cash', customer_name text, customer_phone text,
  customer_id uuid references public.customers(id) on delete set null,
  staff_id uuid references public.profiles(id) on delete set null, canceled_at timestamptz,
  tax_total numeric(12,2) not null default 0, gst_details jsonb
);
create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(), sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid not null references public.products(id), batch_id uuid references public.batches(id) on delete set null,
  quantity numeric(12,3) not null check(quantity>0), price numeric(12,2) not null check(price>=0), mrp numeric(12,2),
  cost_price numeric(12,2), gst_rate numeric(5,2)
);
create table if not exists public.customer_payments (
  id uuid primary key default gen_random_uuid(), customer_id uuid not null references public.customers(id) on delete restrict,
  sale_id uuid references public.sales(id) on delete set null,
  amount numeric(12,2) not null check(amount>0), paid_on date not null default current_date,
  mode text not null check(mode in ('cash','upi')), note text,
  created_by uuid references auth.users(id) on delete set null, canceled_at timestamptz
);
create table if not exists public.product_changes (
  id uuid primary key default gen_random_uuid(), product_id uuid not null,
  product_name text not null, changed_by uuid references auth.users(id) on delete set null,
  field_name text not null, old_value text, new_value text,
  created_at timestamptz not null default now()
);
create table if not exists public.stock_adjustments (
  id uuid primary key default gen_random_uuid(), batch_id uuid, product_id uuid,
  product_name text not null, batch_mfg_date date, batch_expiry_date date,
  units_before numeric(12,3), delta numeric(12,3) not null,
  reason text not null, who uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.shop_settings (key text primary key, value jsonb not null default '{}'::jsonb);

create index if not exists batches_fefo_idx on public.batches(product_id,expiry_date nulls last,created_at);
create index if not exists batches_import_id_idx on public.batches(import_id) where import_id is not null;
create index if not exists purchases_supplier_date_idx on public.purchases(supplier_id,bill_date desc);
create index if not exists purchase_payments_purchase_idx on public.purchase_payments(purchase_id) where canceled_at is null;
create index if not exists product_changes_product_created_idx on public.product_changes(product_id,created_at desc);
create index if not exists stock_adjustments_product_created_idx on public.stock_adjustments(product_id,created_at desc);
create index if not exists customer_payments_customer_idx on public.customer_payments(customer_id,paid_on desc) where canceled_at is null;
create index if not exists sales_created_at_idx on public.sales(created_at desc);
create index if not exists sale_items_product_idx on public.sale_items(product_id);

create or replace function public.owner_customer_records() returns table(id uuid,name text,phone text,created_at timestamptz)
language sql stable security definer set search_path=public
as $$ select c.id,c.name,c.phone,c.created_at from public.customers c where public.is_store_owner() order by c.name $$;
revoke all on function public.owner_customer_records() from public,anon;
grant execute on function public.owner_customer_records() to authenticated;

create or replace function public.undo_stock_import(p_import_id uuid) returns void
language plpgsql security definer set search_path=public
as $$
declare j public.stock_imports%rowtype; prior jsonb;
begin
  if not public.is_store_owner() then raise exception 'Owner access required'; end if;
  select * into j from public.stock_imports where id=p_import_id for update;
  if not found or j.status<>'complete' then raise exception 'Import not found or already undone'; end if;
  if now()>j.created_at+interval '10 minutes' then raise exception 'The 10-minute undo period has expired'; end if;
  update public.batches set units=0 where import_id=p_import_id and id in(select batch_id from public.sale_items where batch_id is not null);
  delete from public.batches where import_id=p_import_id and id not in(select batch_id from public.sale_items where batch_id is not null);
  for prior in select value from jsonb_array_elements(coalesce(j.undo_details->'previous_batches','[]'::jsonb)) loop
    update public.batches set units=(prior->>'units')::numeric where id=(prior->>'id')::uuid;
  end loop;
  delete from public.products p where p.created_import_id=p_import_id and not exists(select 1 from public.sale_items i where i.product_id=p.id) and not exists(select 1 from public.batches b where b.product_id=p.id);
  update public.stock_imports set status='undone',undone_at=now() where id=p_import_id;
end $$;
revoke all on function public.undo_stock_import(uuid) from public,anon;
grant execute on function public.undo_stock_import(uuid) to authenticated;

create or replace function public.create_sale(
  p_items jsonb,p_payment public.payment_mode,p_discount numeric default 0,
  p_customer_name text default null,p_customer_phone text default null,
  p_customer_id uuid default null,p_paid_now numeric default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare v_sale uuid; v_subtotal numeric(12,2):=0; v_discount numeric(12,2):=coalesce(p_discount,0);
  v_paid numeric(12,2):=coalesce(p_paid_now,0); v_item jsonb; v_pid uuid; v_qty numeric;
  v_price numeric; v_mrp numeric; v_cost numeric; v_hidden boolean; v_left numeric; v_batch record; v_take numeric(12,3); v_customer public.customers%rowtype;
begin
  if auth.uid() is null or not public.is_store_user() then raise exception 'Sign in to create a bill'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item'; end if;
  if p_payment::text='credit' then
    if p_customer_id is null then raise exception 'Choose a customer for a credit bill'; end if;
    select * into v_customer from public.customers where id=p_customer_id;
    if not found then raise exception 'Customer not found'; end if;
  elsif p_paid_now is not null then raise exception 'Paid-now amount is only valid for credit bills'; end if;
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

create or replace function public.cancel_sale(p_sale_id uuid) returns void
language plpgsql security definer set search_path=public
as $$ begin
  if not public.is_store_owner() then raise exception 'Owner access required'; end if;
  perform 1 from public.sales where id=p_sale_id and canceled_at is null for update;
  if not found then raise exception 'Bill not found or already cancelled'; end if;
  update public.batches b set units=b.units+i.quantity from public.sale_items i where i.sale_id=p_sale_id and i.batch_id=b.id;
  update public.sales set canceled_at=now() where id=p_sale_id;
end $$;
revoke all on function public.cancel_sale(uuid) from public,anon;
grant execute on function public.cancel_sale(uuid) to authenticated;

create or replace function public.set_staff_active(p_staff_id uuid,p_active boolean) returns void
language plpgsql security definer set search_path=public
as $$ begin
  if not public.is_store_owner() then raise exception 'Owner access required'; end if;
  update public.profiles set active=p_active where id=p_staff_id and role='staff';
  if not found then raise exception 'Staff account not found'; end if;
end $$;
revoke all on function public.set_staff_active(uuid,boolean) from public,anon;
grant execute on function public.set_staff_active(uuid,boolean) to authenticated;

-- RLS is intentionally on for every store table. Grants alone never grant access without policy checks.
alter table public.profiles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.batches enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.shop_settings enable row level security;
alter table public.product_changes enable row level security;
alter table public.stock_adjustments enable row level security;
alter table public.stock_imports enable row level security;
alter table public.expired_stock_removals enable row level security;
alter table public.suppliers enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_payments enable row level security;
alter table public.customers enable row level security;
alter table public.customer_payments enable row level security;

-- Remove prototype policy names when upgrading this schema file on a project by mistake.
drop policy if exists "signed-in users read profiles" on public.profiles;
drop policy if exists "owners manage profiles" on public.profiles;
drop policy if exists "signed-in users read products" on public.products;
drop policy if exists "signed-in users add products" on public.products;
drop policy if exists "owners update products" on public.products;
drop policy if exists "owners delete products" on public.products;
drop policy if exists "signed-in users update products" on public.products;
drop policy if exists "signed-in users delete products" on public.products;
drop policy if exists "signed-in users read batches" on public.batches;
drop policy if exists "signed-in users add batches" on public.batches;
drop policy if exists "owners correct batches" on public.batches;
drop policy if exists "owners delete batches" on public.batches;
drop policy if exists "signed-in users update batches" on public.batches;
drop policy if exists "signed-in users delete batches" on public.batches;
drop policy if exists "owners read sales" on public.sales;
drop policy if exists "signed-in users create sales" on public.sales;
drop policy if exists "owners manage sales" on public.sales;
drop policy if exists "owners read sale items" on public.sale_items;
drop policy if exists "signed-in users create sale items" on public.sale_items;
drop policy if exists "owners manage sale items" on public.sale_items;
drop policy if exists profiles_read_self_or_owner on public.profiles;
create policy profiles_read_self_or_owner on public.profiles for select to authenticated using(id=auth.uid() or public.is_store_owner());
drop policy if exists categories_read on public.categories;
create policy categories_read on public.categories for select to authenticated using(public.is_store_user());
drop policy if exists categories_owner_all on public.categories;
create policy categories_owner_all on public.categories for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists products_read on public.products;
create policy products_read on public.products for select to authenticated using(public.is_store_user());
drop policy if exists products_owner_insert on public.products;
create policy products_owner_insert on public.products for insert to authenticated with check(public.is_store_owner());
drop policy if exists products_owner_update on public.products;
create policy products_owner_update on public.products for update to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists products_owner_delete on public.products;
create policy products_owner_delete on public.products for delete to authenticated using(public.is_store_owner());
drop policy if exists batches_read on public.batches;
create policy batches_read on public.batches for select to authenticated using(public.is_store_user());
drop policy if exists batches_add_stock on public.batches;
drop policy if exists "signed-in users add batches" on public.batches;
create policy batches_add_stock on public.batches for insert to authenticated
with check(public.is_store_user() and (public.is_store_owner() or (cost_price is null and purchase_id is null)));
drop policy if exists batches_owner_update on public.batches;
create policy batches_owner_update on public.batches for update to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists batches_owner_delete on public.batches;
create policy batches_owner_delete on public.batches for delete to authenticated using(public.is_store_owner());
drop policy if exists sales_read_owner_or_self on public.sales;
create policy sales_read_owner_or_self on public.sales for select to authenticated using(public.is_store_user() and (public.is_store_owner() or staff_id=auth.uid()));
drop policy if exists sale_items_read_owner_or_self on public.sale_items;
create policy sale_items_read_owner_or_self on public.sale_items for select to authenticated using(public.is_store_user() and (public.is_store_owner() or exists(select 1 from public.sales s where s.id=sale_id and s.staff_id=auth.uid())));
drop policy if exists product_changes_owner_all on public.product_changes;
create policy product_changes_owner_all on public.product_changes for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists stock_adjustments_owner_all on public.stock_adjustments;
create policy stock_adjustments_owner_all on public.stock_adjustments for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists settings_read on public.shop_settings;
create policy settings_read on public.shop_settings for select to authenticated using(public.is_store_user());
drop policy if exists settings_owner_write on public.shop_settings;
create policy settings_owner_write on public.shop_settings for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists stock_imports_owner_select on public.stock_imports;
create policy stock_imports_owner_select on public.stock_imports for select to authenticated using(public.is_store_owner());
drop policy if exists stock_imports_owner_insert on public.stock_imports;
create policy stock_imports_owner_insert on public.stock_imports for insert to authenticated with check(public.is_store_owner() and created_by=auth.uid());
drop policy if exists stock_imports_owner_update on public.stock_imports;
create policy stock_imports_owner_update on public.stock_imports for update to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
drop policy if exists expired_stock_owner_select on public.expired_stock_removals;
create policy expired_stock_owner_select on public.expired_stock_removals for select to authenticated using(public.is_store_owner());
drop policy if exists expired_stock_owner_insert on public.expired_stock_removals;
create policy expired_stock_owner_insert on public.expired_stock_removals for insert to authenticated with check(public.is_store_owner() and removed_by=auth.uid());
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

-- Explicit grants for new tables and the existing app tables used by authenticated sessions.
grant select,insert,update,delete on public.profiles,public.categories,public.products,public.batches,public.sales,public.sale_items,public.shop_settings,public.product_changes,public.stock_adjustments to authenticated;
grant select,insert,update on public.stock_imports to authenticated;
grant select,insert on public.expired_stock_removals to authenticated;
grant select,insert,update,delete on public.suppliers,public.purchases,public.purchase_payments to authenticated;
grant insert,update,delete on public.customers to authenticated;
revoke select on public.customers from public,anon,authenticated;
grant select(id,name,phone) on public.customers to authenticated;
grant select,insert,update,delete on public.customer_payments to authenticated;

-- Realtime: enable for products, batches, and sales in Supabase Database > Replication.
