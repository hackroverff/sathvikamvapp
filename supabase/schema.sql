-- Sathvika M V Store — initial Supabase schema
-- Run in Supabase SQL Editor. Never expose a service-role key in the client.
create extension if not exists pgcrypto;
create type public.store_role as enum ('owner','staff');
create type public.unit_type as enum ('piece','kg','litre');
create type public.payment_mode as enum ('cash','upi');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.store_role not null default 'staff',
  display_name text,
  created_at timestamptz not null default now()
);
create or replace function public.create_profile_for_user() returns trigger
language plpgsql security definer set search_path=public
as $$ begin insert into public.profiles(id,display_name) values(new.id,coalesce(new.raw_user_meta_data->>'name',new.email)); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.create_profile_for_user();
create table public.products (
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
create table public.batches (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  mfg_date date,
  expiry_date date,
  units integer not null check (units >= 0),
  created_at timestamptz not null default now(),
  check (mfg_date is null or expiry_date is null or expiry_date > mfg_date)
);
create table public.sales (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  total numeric(12,2) not null check (total >= 0),
  payment_mode public.payment_mode not null default 'cash',
  staff_id uuid references public.profiles(id)
);
create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid not null references public.products(id),
  batch_id uuid references public.batches(id),
  quantity numeric(12,3) not null check (quantity > 0),
  price numeric(12,2) not null check (price >= 0)
);
create index batches_product_expiry_idx on public.batches(product_id, expiry_date);
create index sales_created_at_idx on public.sales(created_at desc);
create index sale_items_product_idx on public.sale_items(product_id);

create or replace function public.current_store_role() returns public.store_role
language sql stable security definer set search_path=public
as $$ select role from public.profiles where id=auth.uid() $$;
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path=public
as $$ select coalesce(public.current_store_role()='owner',false) $$;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.batches enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;

-- A single-store deployment: signed-in staff can read inventory and create stock records.
create policy "signed-in users read profiles" on public.profiles for select to authenticated using (true);
create policy "owners manage profiles" on public.profiles for all to authenticated using (public.is_owner()) with check (public.is_owner());
create policy "signed-in users read products" on public.products for select to authenticated using (true);
create policy "signed-in users add products" on public.products for insert to authenticated with check (true);
create policy "owners update products" on public.products for update to authenticated using (public.is_owner()) with check (public.is_owner());
create policy "owners delete products" on public.products for delete to authenticated using (public.is_owner());
create policy "signed-in users read batches" on public.batches for select to authenticated using (true);
create policy "signed-in users add batches" on public.batches for insert to authenticated with check (true);
create policy "owners correct batches" on public.batches for update to authenticated using (public.is_owner()) with check (public.is_owner());
create policy "owners delete batches" on public.batches for delete to authenticated using (public.is_owner());
create policy "owners read sales" on public.sales for select to authenticated using (public.is_owner());
create policy "signed-in users create sales" on public.sales for insert to authenticated with check (true);
create policy "owners manage sales" on public.sales for update to authenticated using (public.is_owner()) with check (public.is_owner());
create policy "owners read sale items" on public.sale_items for select to authenticated using (public.is_owner());
create policy "signed-in users create sale items" on public.sale_items for insert to authenticated with check (true);
create policy "owners manage sale items" on public.sale_items for update to authenticated using (public.is_owner()) with check (public.is_owner());

-- Create the first auth user through Supabase Auth, then promote it:
-- update public.profiles set role='owner' where id='AUTH_USER_UUID';
-- For production staff onboarding, use an Edge Function/admin invite; do not grant client users admin access.
-- For multiple shops, add a store_id to every table and enforce membership in every policy.
