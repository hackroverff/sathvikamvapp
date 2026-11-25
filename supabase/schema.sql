-- Sathvika M V Store — final schema for a fresh Supabase project.
-- Existing databases should be upgraded in order with migration_v3.sql (if v2), migration_v4.sql, then migration_v5.sql.
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

-- Final v5 upgrade overlay for fresh installs. Existing projects apply migration_v5.sql after v4.
-- Sathvika M V v5: private buying prices, suppliers/returns, expiry settings and restock support.
-- Apply after migration_v4.sql. Additive/idempotent; legacy cost columns are retained but no longer exposed to authenticated clients.

alter table public.products add column if not exists default_supplier_id uuid references public.suppliers(id) on delete set null;
alter table public.sale_items add column if not exists mrp_snapshot boolean not null default false;
alter table public.suppliers add column if not exists return_window_months integer check(return_window_months is null or return_window_months between 0 and 120);

create table if not exists public.product_costs (
  product_id uuid primary key references public.products(id) on delete cascade,
  buying_price numeric(12,2) check(buying_price is null or buying_price>=0),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create table if not exists public.batch_costs (
  batch_id uuid primary key references public.batches(id) on delete cascade,
  buying_price numeric(12,2) check(buying_price is null or buying_price>=0),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create table if not exists public.sale_item_costs (
  sale_item_id uuid primary key references public.sale_items(id) on delete cascade,
  buying_price numeric(12,2) not null check(buying_price>=0),
  supplier_id uuid references public.suppliers(id) on delete set null
);
alter table public.sale_item_costs add column if not exists supplier_id uuid references public.suppliers(id) on delete set null;

-- Preserve existing prices in owner-only tables. Legacy columns are deliberately not dropped.
insert into public.product_costs(product_id,buying_price)
select id,cost_price from public.products where cost_price is not null
on conflict(product_id) do nothing;
insert into public.batch_costs(batch_id,buying_price)
select id,cost_price from public.batches where cost_price is not null
on conflict(batch_id) do nothing;
insert into public.sale_item_costs as existing_cost(sale_item_id,buying_price,supplier_id)
select i.id,i.cost_price,p.default_supplier_id from public.sale_items i join public.products p on p.id=i.product_id where i.cost_price is not null
on conflict(sale_item_id) do update set supplier_id=coalesce(existing_cost.supplier_id,excluded.supplier_id);

create table if not exists public.supplier_returns (
  id uuid primary key default gen_random_uuid(), supplier_id uuid references public.suppliers(id) on delete set null,
  supplier_name text not null, status text not null default 'Draft' check(status in ('Draft','Sent','Credited','Rejected','Cancelled')),
  reason text, note text, receipt_number text, returned_on date, receipt_amount numeric(12,2),
  settlement text check(settlement is null or settlement in ('reduce_owed','cash','upi','bank','credit')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.supplier_return_items (
  id uuid primary key default gen_random_uuid(), return_id uuid not null references public.supplier_returns(id) on delete cascade,
  batch_id uuid, product_id uuid, product_name text not null, units numeric(12,3) not null check(units>0),
  expiry_date date, buying_price numeric(12,2), expected_credit numeric(12,2),
  created_at timestamptz not null default now()
);
create table if not exists public.stock_writeoffs (
  id uuid primary key default gen_random_uuid(), batch_id uuid, product_id uuid,
  product_name text not null, units numeric(12,3) not null check(units>0), buying_price numeric(12,2),
  value_lost numeric(12,2), reason text not null default 'expired', written_off_by uuid references auth.users(id) on delete set null,
  written_off_at timestamptz not null default now()
);
create table if not exists public.restock_orders (
  id uuid primary key default gen_random_uuid(), product_id uuid references public.products(id) on delete set null,
  requested_units numeric(12,3) not null default 1 check(requested_units>0), status text not null default 'ordered' check(status in ('ordered','waiting_return','received','cancelled')),
  created_by uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(), completed_at timestamptz
);
create index if not exists product_costs_supplier_idx on public.products(default_supplier_id);
create index if not exists supplier_returns_supplier_date_idx on public.supplier_returns(supplier_id,created_at desc);
create index if not exists supplier_return_items_return_idx on public.supplier_return_items(return_id);
create index if not exists stock_writeoffs_date_idx on public.stock_writeoffs(written_off_at desc);
create index if not exists restock_orders_product_status_idx on public.restock_orders(product_id,status);
alter table public.restock_orders alter column product_id drop not null;
DO $$ begin
  if exists(select 1 from pg_constraint where conrelid='public.restock_orders'::regclass and conname='restock_orders_product_id_fkey' and confdeltype<>'n') then
    alter table public.restock_orders drop constraint restock_orders_product_id_fkey;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.restock_orders'::regclass and conname='restock_orders_product_id_fkey') then
    alter table public.restock_orders add constraint restock_orders_product_id_fkey foreign key(product_id) references public.products(id) on delete set null;
  end if;
end $$;

-- New tables are owner-only and explicitly granted to authenticated (RLS remains authoritative).
revoke all on public.product_costs,public.batch_costs,public.sale_item_costs,public.supplier_returns,public.supplier_return_items,public.stock_writeoffs,public.restock_orders from anon,public;
grant select,insert,update,delete on public.product_costs,public.batch_costs,public.sale_item_costs,public.supplier_returns,public.supplier_return_items,public.stock_writeoffs,public.restock_orders to authenticated;
DO $$ declare t text; begin
  foreach t in array array['product_costs','batch_costs','sale_item_costs','supplier_returns','supplier_return_items','stock_writeoffs','restock_orders'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists %I on public.%I',t||'_owner_all',t);
    execute format('create policy %I on public.%I for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner())',t||'_owner_all',t);
  end loop;
end $$;

-- Keep public catalog columns selectable, but revoke access to legacy buying-price columns.
revoke select on public.products from public,anon,authenticated;
grant select(id,barcode,name,category,mrp,selling_price,mrp_confirmed,hidden,unit_type,low_stock_limit,created_import_id,created_at) on public.products to authenticated;
revoke insert,update on public.products from public,anon,authenticated;
grant insert(barcode,name,category,mrp,selling_price,mrp_confirmed,hidden,unit_type,low_stock_limit,created_import_id,default_supplier_id) on public.products to authenticated;
grant update(barcode,name,category,mrp,selling_price,mrp_confirmed,hidden,unit_type,low_stock_limit,default_supplier_id) on public.products to authenticated;
grant delete on public.products to authenticated;

revoke select on public.batches from public,anon,authenticated;
grant select(id,product_id,mfg_date,expiry_date,units,discounted,client_op_id,import_id,purchase_id,deleted_at,created_at) on public.batches to authenticated;
revoke insert,update on public.batches from public,anon,authenticated;
grant insert(product_id,mfg_date,expiry_date,units,discounted,client_op_id,import_id,purchase_id,deleted_at) on public.batches to authenticated;
grant update(mfg_date,expiry_date,units,discounted,import_id,purchase_id,deleted_at) on public.batches to authenticated;
grant delete on public.batches to authenticated;

revoke select on public.sale_items from public,anon,authenticated;
grant select(id,sale_id,product_id,batch_id,quantity,price,mrp,mrp_snapshot,gst_rate) on public.sale_items to authenticated;
grant insert,update,delete on public.sale_items to authenticated;

create or replace function public.owner_product_cost_records()
returns table(product_id uuid,buying_price numeric,default_supplier_id uuid)
language sql stable security definer set search_path=public
as $$
  select p.id,c.buying_price,p.default_supplier_id from public.products p
  left join public.product_costs c on c.product_id=p.id
  where public.is_store_owner()
$$;
create or replace function public.owner_batch_cost_records()
returns table(batch_id uuid,buying_price numeric)
language sql stable security definer set search_path=public
as $$ select batch_id,buying_price from public.batch_costs where public.is_store_owner() $$;
create or replace function public.owner_sale_item_cost_records()
returns table(sale_item_id uuid,buying_price numeric)
language sql stable security definer set search_path=public
as $$ select sale_item_id,buying_price from public.sale_item_costs where public.is_store_owner() $$;
create or replace function public.owner_sale_item_cost_details()
returns table(sale_item_id uuid,buying_price numeric,supplier_id uuid)
language sql stable security definer set search_path=public
as $$ select sale_item_id,buying_price,supplier_id from public.sale_item_costs where public.is_store_owner() $$;
revoke all on function public.owner_product_cost_records() from public,anon;
revoke all on function public.owner_batch_cost_records() from public,anon;
revoke all on function public.owner_sale_item_cost_records() from public,anon;
revoke all on function public.owner_sale_item_cost_details() from public,anon;
grant execute on function public.owner_product_cost_records() to authenticated;
grant execute on function public.owner_batch_cost_records() to authenticated;
grant execute on function public.owner_sale_item_cost_records() to authenticated;
grant execute on function public.owner_sale_item_cost_details() to authenticated;

-- Owner-only cost-aware supplier data RPC; staff cannot query supplier or buying-price records.
create or replace function public.owner_supplier_profit_records()
returns table(supplier_id uuid,product_id uuid,product_name text,buying_price numeric,selling_price numeric,units numeric,default_supplier_id uuid)
language sql stable security definer set search_path=public
as $$
  select s.id,p.id,p.name,c.buying_price,coalesce(p.selling_price,p.mrp),
    coalesce(sum(case when b.expiry_date is null or b.expiry_date>=current_date then b.units else 0 end),0),p.default_supplier_id
  from public.suppliers s left join public.products p on p.default_supplier_id=s.id
  left join public.product_costs c on c.product_id=p.id
  left join public.batches b on b.product_id=p.id
  where public.is_store_owner()
  group by s.id,p.id,p.name,c.buying_price,p.selling_price,p.mrp,p.default_supplier_id
$$;
revoke all on function public.owner_supplier_profit_records() from public,anon;
grant execute on function public.owner_supplier_profit_records() to authenticated;

create or replace function public.owner_supplier_sales_profit_records()
returns table(supplier_id uuid,supplier_name text,items_sold numeric,sales_revenue numeric,buying_cost numeric,profit numeric)
language sql stable security definer set search_path=public
as $$
  select v.id,v.name,coalesce(sum(i.quantity),0),coalesce(sum(i.quantity*i.price),0),
    coalesce(sum(i.quantity*c.buying_price),0),coalesce(sum(i.quantity*(i.price-c.buying_price)),0)
  from public.suppliers v join public.sale_item_costs c on c.supplier_id=v.id
  join public.sale_items i on i.id=c.sale_item_id join public.sales s on s.id=i.sale_id
  where public.is_store_owner() and s.canceled_at is null
  group by v.id,v.name
$$;
revoke all on function public.owner_supplier_sales_profit_records() from public,anon;
grant execute on function public.owner_supplier_sales_profit_records() to authenticated;

create or replace function public.create_sale(
  p_items jsonb,p_payment public.payment_mode,p_discount numeric default 0,
  p_customer_name text default null,p_customer_phone text default null,
  p_customer_id uuid default null,p_paid_now numeric default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare v_sale uuid; v_subtotal numeric(12,2):=0; v_discount numeric(12,2):=coalesce(p_discount,0);
  v_paid numeric(12,2):=coalesce(p_paid_now,0); v_item jsonb; v_pid uuid; v_qty numeric;
  v_price numeric; v_mrp numeric; v_cost numeric; v_hidden boolean; v_left numeric; v_batch record; v_take numeric(12,3); v_sale_item uuid; v_supplier_id uuid;
  v_customer public.customers%rowtype;
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
    select coalesce(p.selling_price,p.mrp),p.mrp,p.hidden,c.buying_price,p.default_supplier_id into v_price,v_mrp,v_hidden,v_cost,v_supplier_id
      from public.products p left join public.product_costs c on c.product_id=p.id where p.id=v_pid for update of p;
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
    select coalesce(p.selling_price,p.mrp),p.mrp,p.hidden,c.buying_price,p.default_supplier_id into v_price,v_mrp,v_hidden,v_cost,v_supplier_id
      from public.products p left join public.product_costs c on c.product_id=p.id where p.id=v_pid;
    for v_batch in select b.id,b.units,bc.buying_price from public.batches b left join public.batch_costs bc on bc.batch_id=b.id
      where b.product_id=v_pid and b.units>0 and b.deleted_at is null and (b.expiry_date is null or b.expiry_date>=current_date)
      order by b.expiry_date nulls last,b.created_at for update of b loop
      exit when v_left<=0; v_take:=least(v_left,v_batch.units);
      update public.batches set units=units-v_take where id=v_batch.id;
      insert into public.sale_items(sale_id,product_id,batch_id,quantity,price,mrp,mrp_snapshot)
      values(v_sale,v_pid,v_batch.id,v_take,v_price,v_mrp,true) returning id into v_sale_item;
      if coalesce(v_batch.buying_price,v_cost) is not null then
        insert into public.sale_item_costs(sale_item_id,buying_price,supplier_id) values(v_sale_item,coalesce(v_batch.buying_price,v_cost),v_supplier_id);
      end if;
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

-- Explicitly remove any pre-existing column-level grants on legacy private fields.
revoke select(cost_price) on public.products,public.batches,public.sale_items from public,anon,authenticated;
revoke select(default_supplier_id) on public.products from public,anon,authenticated;
revoke insert(cost_price),update(cost_price) on public.products,public.batches,public.sale_items from public,anon,authenticated;
revoke insert(default_supplier_id),update(default_supplier_id) on public.products from public,anon,authenticated;
grant insert(default_supplier_id),update(default_supplier_id) on public.products to authenticated;

create or replace function public.owner_set_product_cost(p_product_id uuid,p_buying_price numeric,p_supplier_id uuid default null)
returns void language plpgsql security definer set search_path=public
as $$ begin
  if not public.is_store_owner() then raise exception 'Owner access only'; end if;
  if p_buying_price is not null and p_buying_price<0 then raise exception 'Buying price cannot be negative'; end if;
  if p_supplier_id is not null and not exists(select 1 from public.suppliers where id=p_supplier_id) then raise exception 'Supplier not found'; end if;
  insert into public.product_costs(product_id,buying_price,updated_by,updated_at) values(p_product_id,p_buying_price,auth.uid(),now()) on conflict(product_id) do update set buying_price=excluded.buying_price,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
  update public.products set default_supplier_id=p_supplier_id where id=p_product_id;
  if not found then raise exception 'Product not found'; end if;
end $$;
create or replace function public.owner_set_batch_cost(p_batch_id uuid,p_buying_price numeric)
returns void language plpgsql security definer set search_path=public
as $$ begin
  if not public.is_store_owner() then raise exception 'Owner access only'; end if;
  if p_buying_price is not null and p_buying_price<0 then raise exception 'Buying price cannot be negative'; end if;
  insert into public.batch_costs(batch_id,buying_price,updated_by,updated_at) values(p_batch_id,p_buying_price,auth.uid(),now()) on conflict(batch_id) do update set buying_price=excluded.buying_price,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
end $$;
revoke all on function public.owner_set_product_cost(uuid,numeric,uuid) from public,anon;
revoke all on function public.owner_set_batch_cost(uuid,numeric) from public,anon;
grant execute on function public.owner_set_product_cost(uuid,numeric,uuid) to authenticated;
grant execute on function public.owner_set_batch_cost(uuid,numeric) to authenticated;

-- Sale lines are written only by the security-definer billing RPC. Do not grant table-level INSERT,
-- which would override column revokes and permit a client to submit cost_price directly.
revoke insert,update,delete on public.sale_items from public,anon,authenticated;
grant select(id,sale_id,product_id,batch_id,quantity,price,mrp,mrp_snapshot,gst_rate) on public.sale_items to authenticated;

create or replace function public.owner_submit_supplier_return(p_supplier_id uuid,p_note text,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_return uuid; v_item jsonb; v_batch uuid; v_units numeric; v_product uuid; v_name text; v_cost numeric; v_supplier text; v_product_supplier uuid; v_available numeric; v_changed integer;
begin
  if not public.is_store_owner() then raise exception 'Owner access only'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Choose at least one stock batch'; end if;
  select name into v_supplier from public.suppliers where id=p_supplier_id;
  if v_supplier is null then raise exception 'Supplier not found'; end if;
  insert into public.supplier_returns(supplier_id,supplier_name,status,note,created_by,returned_on)
    values(p_supplier_id,v_supplier,'Draft',nullif(trim(p_note),''),auth.uid(),current_date) returning id into v_return;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_batch:=(v_item->>'batch_id')::uuid; v_units:=(v_item->>'units')::numeric;
    select b.product_id,p.name,coalesce(bc.buying_price,pc.buying_price),p.default_supplier_id
      into v_product,v_name,v_cost,v_product_supplier
      from public.batches b join public.products p on p.id=b.product_id
      left join public.batch_costs bc on bc.batch_id=b.id left join public.product_costs pc on pc.product_id=p.id
      where b.id=v_batch and b.deleted_at is null and b.units>0 for update of b;
    if not found then raise exception 'A selected batch is no longer active'; end if;
    if v_product_supplier is distinct from p_supplier_id then raise exception 'Every selected product must be associated with this supplier'; end if;
    select units into v_available from public.batches where id=v_batch;
    if v_units is null or v_units<=0 or v_units>v_available then raise exception 'Return quantity must be positive and no greater than available units'; end if;
    insert into public.supplier_return_items(return_id,batch_id,product_id,product_name,units,expiry_date,buying_price,expected_credit)
      select v_return,v_batch,v_product,v_name,v_units,b.expiry_date,v_cost,v_units*v_cost from public.batches b where b.id=v_batch;
  end loop;
  return v_return;
end $$;

create or replace function public.owner_update_supplier_return(p_return_id uuid,p_status text,p_settlement text default null,p_receipt_amount numeric default null)
returns void language plpgsql security definer set search_path=public
as $$
declare v_old text; v_item record; v_after numeric; v_changed integer;
begin
  if not public.is_store_owner() then raise exception 'Owner access only'; end if;
  if p_status not in ('Sent','Credited','Rejected','Cancelled') then raise exception 'Invalid return status'; end if;
  if p_status='Credited' and (p_settlement is null or p_settlement not in ('reduce_owed','cash','upi','bank','credit') or p_receipt_amount is null or p_receipt_amount<0) then raise exception 'Choose a valid settlement and non-negative credit amount'; end if;
  select status into v_old from public.supplier_returns where id=p_return_id for update;
  if not found then raise exception 'Return not found'; end if;
  if v_old='Draft' and p_status='Sent' then
    for v_item in select i.batch_id,i.units,i.product_id,i.product_name,i.expiry_date,b.mfg_date from public.supplier_return_items i left join public.batches b on b.id=i.batch_id where i.return_id=p_return_id loop
      update public.batches set units=units-v_item.units where id=v_item.batch_id and deleted_at is null and units>=v_item.units returning units into v_after;
      get diagnostics v_changed=row_count;
      if v_changed=0 then raise exception 'Not enough stock remains for this return'; end if;
      insert into public.stock_adjustments(batch_id,product_id,product_name,batch_mfg_date,batch_expiry_date,units_before,delta,reason,who)
        values(v_item.batch_id,v_item.product_id,v_item.product_name,v_item.mfg_date,v_item.expiry_date,v_after+v_item.units,-v_item.units,'supplier return sent',auth.uid());
    end loop;
  elsif v_old='Sent' and p_status in ('Rejected','Cancelled') then
    for v_item in select i.batch_id,i.units,i.product_id,i.product_name,i.expiry_date,b.mfg_date,b.units as current_units from public.supplier_return_items i left join public.batches b on b.id=i.batch_id where i.return_id=p_return_id loop
      if v_item.batch_id is not null and v_item.current_units is not null then
        update public.batches set units=units+v_item.units,deleted_at=null where id=v_item.batch_id returning units into v_after;
        insert into public.stock_adjustments(batch_id,product_id,product_name,batch_mfg_date,batch_expiry_date,units_before,delta,reason,who)
          values(v_item.batch_id,v_item.product_id,v_item.product_name,v_item.mfg_date,v_item.expiry_date,v_after-v_item.units,v_item.units,'supplier return rejected',auth.uid());
      else
        insert into public.batches(product_id,expiry_date,units) values(v_item.product_id,v_item.expiry_date,v_item.units);
        insert into public.stock_adjustments(product_id,product_name,batch_expiry_date,units_before,delta,reason,who)
          values(v_item.product_id,v_item.product_name,v_item.expiry_date,0,v_item.units,'supplier return rejected',auth.uid());
      end if;
    end loop;
  elsif not ((v_old='Sent' and p_status='Credited') or (v_old='Draft' and p_status in ('Cancelled','Sent')) or (v_old='Sent' and p_status='Cancelled')) then
    raise exception 'Invalid status transition';
  end if;
  update public.supplier_returns set status=p_status,settlement=case when p_status='Credited' then p_settlement else settlement end,
    receipt_amount=case when p_status='Credited' then p_receipt_amount else receipt_amount end,updated_at=now() where id=p_return_id;
end $$;
revoke all on function public.owner_submit_supplier_return(uuid,text,jsonb) from public,anon;
revoke all on function public.owner_update_supplier_return(uuid,text,text,numeric) from public,anon;
grant execute on function public.owner_submit_supplier_return(uuid,text,jsonb) to authenticated;
grant execute on function public.owner_update_supplier_return(uuid,text,text,numeric) to authenticated;

-- Return inventory is mutated only through the stock-adjusting owner RPCs.
revoke insert,update,delete on public.supplier_returns,public.supplier_return_items from public,anon,authenticated;
grant select on public.supplier_returns,public.supplier_return_items to authenticated;
revoke insert,update,delete on public.sale_item_costs from public,anon,authenticated;
grant select on public.sale_item_costs to authenticated;
