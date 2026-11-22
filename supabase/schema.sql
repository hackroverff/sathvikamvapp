-- Sathvika M V Store — fresh Supabase schema
-- Run this once in Supabase > SQL Editor on a fresh project. Do not expose service_role keys.
create extension if not exists pgcrypto;

do $$ begin create type public.store_role as enum ('owner','staff'); exception when duplicate_object then null; end $$;
do $$ begin create type public.payment_mode as enum ('cash','upi'); exception when duplicate_object then null; end $$;
do $$ begin create type public.unit_type as enum ('piece','kg','litre'); exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.store_role not null default 'staff',
  display_name text not null default '',
  email text unique,
  active boolean not null default false,
  created_at timestamptz not null default now()
);
-- Safe upgrades from the earlier app schema (where a manually assigned owner role was active by definition).
alter table public.profiles add column if not exists email text;
do $$ declare had_active boolean; begin
  select exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='active') into had_active;
  if not had_active then
    alter table public.profiles add column active boolean not null default false;
    update public.profiles set active=true;
  end if;
end $$;
create unique index if not exists profiles_email_unique_idx on public.profiles(email) where email is not null;
create or replace function public.create_profile_for_user() returns trigger
language plpgsql security definer set search_path=public
as $$ begin insert into public.profiles(id,display_name,email,active) values(new.id,coalesce(new.raw_user_meta_data->>'name',split_part(new.email,'@',1)),new.email,false) on conflict(id) do nothing; return new; end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.create_profile_for_user();

create or replace function public.owner_exists() returns boolean
language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where role='owner' and active) $$;
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
revoke all on function public.claim_first_owner() from public, anon;
grant execute on function public.claim_first_owner() to authenticated;
create or replace function public.is_store_owner() returns boolean
language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='owner' and active) $$;
create or replace function public.is_store_user() returns boolean
language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role in ('owner','staff') and active) $$;

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  barcode text unique,
  name text not null,
  category text not null default 'General',
  mrp numeric(12,2) not null check (mrp >= 0),
  cost_price numeric(12,2) check (cost_price is null or cost_price >= 0),
  unit_type public.unit_type not null default 'piece',
  low_stock_limit integer not null default 8 check (low_stock_limit >= 0),
  created_at timestamptz not null default now()
);
create table if not exists public.batches (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  mfg_date date,
  expiry_date date,
  units numeric(12,3) not null check (units >= 0),
  discounted boolean not null default false,
  client_op_id text unique,
  created_at timestamptz not null default now(),
  check (mfg_date is null or expiry_date is null or expiry_date > mfg_date)
);
alter table public.batches add column if not exists discounted boolean not null default false;
alter table public.batches add column if not exists client_op_id text;
alter table public.batches alter column units type numeric(12,3) using units::numeric;
create unique index if not exists batches_client_op_unique_idx on public.batches(client_op_id) where client_op_id is not null;

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  bill_number bigint generated by default as identity unique,
  created_at timestamptz not null default now(),
  subtotal numeric(12,2) not null default 0 check (subtotal >= 0),
  discount numeric(12,2) not null default 0 check (discount >= 0),
  total numeric(12,2) not null check (total >= 0),
  payment_mode public.payment_mode not null default 'cash',
  customer_name text,
  customer_phone text,
  staff_id uuid references public.profiles(id) on delete set null,
  canceled_at timestamptz,
  tax_total numeric(12,2) not null default 0,
  gst_details jsonb
);
alter table public.sales add column if not exists bill_number bigint generated by default as identity;
alter table public.sales add column if not exists subtotal numeric(12,2) not null default 0;
alter table public.sales add column if not exists discount numeric(12,2) not null default 0;
alter table public.sales add column if not exists customer_name text;
alter table public.sales add column if not exists customer_phone text;
alter table public.sales add column if not exists canceled_at timestamptz;
alter table public.sales add column if not exists tax_total numeric(12,2) not null default 0;
alter table public.sales add column if not exists gst_details jsonb;
alter table public.sales alter column staff_id drop not null;
alter table public.sales drop constraint if exists sales_staff_id_fkey;
alter table public.sales add constraint sales_staff_id_fkey foreign key (staff_id) references public.profiles(id) on delete set null;
create unique index if not exists sales_bill_number_unique_idx on public.sales(bill_number);

create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid not null references public.products(id),
  batch_id uuid references public.batches(id),
  quantity numeric(12,3) not null check (quantity > 0),
  price numeric(12,2) not null check (price >= 0),
  cost_price numeric(12,2),
  gst_rate numeric(5,2)
);
alter table public.sale_items add column if not exists cost_price numeric(12,2);
alter table public.sale_items add column if not exists gst_rate numeric(5,2);

create table if not exists public.shop_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb
);
create index if not exists batches_fefo_idx on public.batches(product_id, expiry_date nulls last, created_at);
create index if not exists sales_created_at_idx on public.sales(created_at desc);
create index if not exists sale_items_product_idx on public.sale_items(product_id);

create or replace function public.create_sale(p_items jsonb,p_payment public.payment_mode,p_discount numeric default 0,p_customer_name text default null,p_customer_phone text default null) returns uuid
language plpgsql security definer set search_path=public
as $$
declare v_sale uuid; v_subtotal numeric(12,2):=0; v_discount numeric(12,2):=coalesce(p_discount,0); v_item jsonb; v_pid uuid; v_qty numeric; v_price numeric; v_cost numeric; v_left numeric; v_batch record; v_take numeric(12,3);
begin
 if auth.uid() is null or not public.is_store_user() then raise exception 'Sign in to create a bill'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item'; end if;
 for v_item in select * from jsonb_array_elements(p_items) loop
  v_pid:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::numeric;
  if v_qty is null or v_qty<=0 then raise exception 'Quantity must be positive'; end if;
  select mrp,cost_price into v_price,v_cost from public.products where id=v_pid for update;
  if not found then raise exception 'Product not found'; end if;
  v_subtotal:=v_subtotal+v_price*v_qty;
 end loop;
 if v_discount<0 then raise exception 'Discount cannot be negative'; end if;
 if v_discount>v_subtotal then raise exception 'Discount cannot be more than the bill'; end if;
 insert into public.sales(subtotal,discount,total,payment_mode,customer_name,customer_phone,staff_id)
 values(v_subtotal,v_discount,v_subtotal-v_discount,p_payment,nullif(trim(p_customer_name),''),nullif(trim(p_customer_phone),''),auth.uid()) returning id into v_sale;
 for v_item in select * from jsonb_array_elements(p_items) loop
  v_pid:=(v_item->>'product_id')::uuid;v_qty:=(v_item->>'quantity')::numeric;v_left:=v_qty;
  select mrp,cost_price into v_price,v_cost from public.products where id=v_pid;
  for v_batch in select id,units from public.batches where product_id=v_pid and units>0 and (expiry_date is null or expiry_date>=current_date) order by expiry_date nulls last,created_at for update loop
   exit when v_left<=0;
   v_take:=least(v_left,v_batch.units);
   update public.batches set units=units-v_take where id=v_batch.id;
   insert into public.sale_items(sale_id,product_id,batch_id,quantity,price,cost_price) values(v_sale,v_pid,v_batch.id,v_take,v_price,v_cost);
   v_left:=v_left-v_take;
  end loop;
  if v_left>0 then raise exception 'Not enough unexpired stock for % (short by %)',(select name from public.products where id=v_pid),v_left; end if;
 end loop;
 return v_sale;
end $$;
revoke all on function public.create_sale(jsonb,public.payment_mode,numeric,text,text) from public, anon;
grant execute on function public.create_sale(jsonb,public.payment_mode,numeric,text,text) to authenticated;

create or replace function public.cancel_sale(p_sale_id uuid) returns void
language plpgsql security definer set search_path=public
as $$ begin
 if not public.is_store_owner() then raise exception 'Owner access required'; end if;
 perform 1 from public.sales where id=p_sale_id and canceled_at is null for update;
 if not found then raise exception 'Bill not found or already cancelled'; end if;
 update public.batches b set units=b.units+i.quantity from public.sale_items i where i.sale_id=p_sale_id and i.batch_id=b.id;
 update public.sales set canceled_at=now() where id=p_sale_id;
end $$;
revoke all on function public.cancel_sale(uuid) from public, anon;
grant execute on function public.cancel_sale(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.batches enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.shop_settings enable row level security;

-- Remove policies from the initial prototype before enabling the stricter role policies below.
drop policy if exists "signed-in users read profiles" on public.profiles;
drop policy if exists "owners manage profiles" on public.profiles;
drop policy if exists "signed-in users read products" on public.products;
drop policy if exists "signed-in users add products" on public.products;
drop policy if exists "owners update products" on public.products;
drop policy if exists "owners delete products" on public.products;
drop policy if exists "signed-in users read batches" on public.batches;
drop policy if exists "signed-in users add batches" on public.batches;
drop policy if exists "owners correct batches" on public.batches;
drop policy if exists "owners delete batches" on public.batches;
drop policy if exists "owners read sales" on public.sales;
drop policy if exists "signed-in users create sales" on public.sales;
drop policy if exists "owners manage sales" on public.sales;
drop policy if exists "owners read sale items" on public.sale_items;
drop policy if exists "signed-in users create sale items" on public.sale_items;
drop policy if exists "owners manage sale items" on public.sale_items;
drop policy if exists profiles_read_self_or_owner on public.profiles;
create policy profiles_read_self_or_owner on public.profiles for select to authenticated using (id=auth.uid() or public.is_store_owner());
drop policy if exists profiles_owner_update on public.profiles;
drop policy if exists categories_read on public.categories;
create policy categories_read on public.categories for select to authenticated using (public.is_store_user());
drop policy if exists categories_owner_all on public.categories;
create policy categories_owner_all on public.categories for all to authenticated using (public.is_store_owner()) with check (public.is_store_owner());
drop policy if exists products_read on public.products;
create policy products_read on public.products for select to authenticated using (public.is_store_user());
drop policy if exists products_owner_insert on public.products;
create policy products_owner_insert on public.products for insert to authenticated with check (public.is_store_owner());
drop policy if exists products_owner_update on public.products;
create policy products_owner_update on public.products for update to authenticated using (public.is_store_owner()) with check (public.is_store_owner());
drop policy if exists products_owner_delete on public.products;
create policy products_owner_delete on public.products for delete to authenticated using (public.is_store_owner());
drop policy if exists batches_read on public.batches;
create policy batches_read on public.batches for select to authenticated using (public.is_store_user());
drop policy if exists batches_add_stock on public.batches;
create policy batches_add_stock on public.batches for insert to authenticated with check (public.is_store_user());
drop policy if exists batches_owner_update on public.batches;
create policy batches_owner_update on public.batches for update to authenticated using (public.is_store_owner()) with check (public.is_store_owner());
drop policy if exists batches_owner_delete on public.batches;
create policy batches_owner_delete on public.batches for delete to authenticated using (public.is_store_owner());
drop policy if exists sales_read_owner_or_self on public.sales;
create policy sales_read_owner_or_self on public.sales for select to authenticated using (public.is_store_user() and (public.is_store_owner() or staff_id=auth.uid()));
drop policy if exists sale_items_read_owner_or_self on public.sale_items;
create policy sale_items_read_owner_or_self on public.sale_items for select to authenticated using (public.is_store_user() and (public.is_store_owner() or exists(select 1 from public.sales s where s.id=sale_id and s.staff_id=auth.uid())));
drop policy if exists settings_read on public.shop_settings;
create policy settings_read on public.shop_settings for select to authenticated using (public.is_store_user());
drop policy if exists settings_owner_write on public.shop_settings;
create policy settings_owner_write on public.shop_settings for all to authenticated using (public.is_store_owner()) with check (public.is_store_owner());

-- Realtime refresh on stock changes (enable Realtime for products/batches in project settings if desired).
-- Invite/manage accounts only through supabase/functions/staff-admin (service key stays server-side).
