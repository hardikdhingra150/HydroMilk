-- Little Ledger / PostgreSQL on Supabase. Run once in the SQL editor.
begin;
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create table public.families (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id),
  invite_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
  settings jsonb not null,
  created_at timestamptz not null default now()
);
create index families_owner on public.families(owner_id);
create table public.memberships (
  user_id uuid primary key references auth.users(id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  display_name text not null check (length(trim(display_name)) between 1 and 60),
  role text not null check (role in ('owner', 'member')),
  created_at timestamptz not null default now()
);
create index memberships_family on public.memberships(family_id);
create table public.deliveries (
  id uuid primary key,
  family_id uuid not null references public.families(id) on delete cascade,
  service text not null check (service in ('milk', 'water')),
  date date not null check (date between '2000-01-01' and '2100-12-31'),
  quantity_milli integer not null check (quantity_milli between 1 and 1000000000),
  rate_paise integer not null check (rate_paise between 0 and 100000000),
  status text not null default 'delivered' check (status in ('delivered', 'skipped')),
  note text not null default '' check (length(note) <= 240),
  amount_paise bigint generated always as (case when status = 'skipped' then 0 else (quantity_milli::bigint * rate_paise + 500) / 1000 end) stored,
  created_at timestamptz not null default now()
);
create index deliveries_family_date on public.deliveries(family_id, date desc, id);
create table public.payments (
  id uuid primary key,
  family_id uuid not null references public.families(id) on delete cascade,
  service text not null check (service in ('milk', 'water')),
  billing_month date not null check (extract(day from billing_month) = 1 and billing_month between '2000-01-01' and '2100-12-01'),
  date date not null check (date between '2000-01-01' and '2100-12-31'),
  amount_paise integer not null check (amount_paise between 1 and 100000000),
  note text not null default '' check (length(note) <= 240),
  created_at timestamptz not null default now()
);
create index payments_family_month on public.payments(family_id, billing_month);

create function private.is_family_member(p_family uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select (select auth.uid()) is not null and exists(select 1 from public.memberships where family_id = p_family and user_id = (select auth.uid()));
$$;
create function private.is_family_owner(p_family uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select (select auth.uid()) is not null and exists(select 1 from public.families where id = p_family and owner_id = (select auth.uid()));
$$;

alter table public.families enable row level security;
alter table public.memberships enable row level security;
alter table public.deliveries enable row level security;
alter table public.payments enable row level security;
create policy family_read on public.families for select to authenticated using (private.is_family_member(id));
create policy member_read on public.memberships for select to authenticated using (private.is_family_member(family_id));
create policy delivery_read on public.deliveries for select to authenticated using (private.is_family_member(family_id));
create policy delivery_add on public.deliveries for insert to authenticated with check (private.is_family_member(family_id));
create policy delivery_edit on public.deliveries for update to authenticated using (private.is_family_member(family_id)) with check (private.is_family_member(family_id));
create policy delivery_delete on public.deliveries for delete to authenticated using (private.is_family_member(family_id));
create policy payment_read on public.payments for select to authenticated using (private.is_family_member(family_id));
create policy payment_add on public.payments for insert to authenticated with check (private.is_family_member(family_id));
create policy payment_delete on public.payments for delete to authenticated using (private.is_family_member(family_id));

create function public.create_family(p_name text, p_display_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare fid uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if length(trim(p_name)) not between 1 and 60 or length(trim(p_display_name)) not between 1 and 60 then raise exception 'Names must contain 1–60 characters'; end if;
  if exists(select 1 from public.memberships where user_id = auth.uid()) then raise exception 'You already belong to a family'; end if;
  insert into public.families(owner_id, settings) values (auth.uid(), jsonb_build_object('name', trim(p_name), 'currency', 'INR', 'milk_supplier', 'Milk supplier', 'water_supplier', 'Water supplier', 'milk_rate', 6000, 'water_rate', 4000, 'milk_quantity', 1000, 'water_quantity', 1000, 'budget', 300000)) returning id into fid;
  insert into public.memberships(user_id, family_id, display_name, role) values(auth.uid(), fid, trim(p_display_name), 'owner');
  return fid;
end;
$$;
create function public.join_family(p_code text, p_display_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare fid uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if length(trim(p_display_name)) not between 1 and 60 then raise exception 'Name must contain 1–60 characters'; end if;
  if exists(select 1 from public.memberships where user_id = auth.uid()) then raise exception 'You already belong to a family'; end if;
  select id into fid from public.families where invite_code = upper(trim(p_code));
  if fid is null then raise exception 'Invite code not found. Check it with your family.'; end if;
  insert into public.memberships(user_id, family_id, display_name, role) values(auth.uid(), fid, trim(p_display_name), 'member');
  return fid;
end;
$$;
create function public.update_family_settings(p_settings jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare fid uuid; k text; n numeric;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select family_id into fid from public.memberships where user_id = auth.uid();
  if fid is null then raise exception 'Join a family first'; end if;
  if p_settings->>'currency' is null or p_settings->>'currency' not in ('INR', 'USD', 'EUR', 'GBP') then raise exception 'Unsupported currency'; end if;
  foreach k in array array['name','milk_supplier','water_supplier'] loop
    if jsonb_typeof(p_settings->k) is distinct from 'string' or length(trim(p_settings->>k)) not between 1 and 60 then raise exception 'Names must contain 1–60 characters'; end if;
  end loop;
  foreach k in array array['milk_rate','water_rate','milk_quantity','water_quantity','budget'] loop
    if jsonb_typeof(p_settings->k) is distinct from 'number' then raise exception 'Numeric setting missing'; end if;
    n := (p_settings->>k)::numeric;
    if n != trunc(n) or n < 0 or n > (case when k in ('milk_quantity','water_quantity') then 1000000000 else 100000000 end) then raise exception 'Setting out of range'; end if;
    if k in ('milk_quantity','water_quantity') and n = 0 then raise exception 'Quantity must be positive'; end if;
  end loop;
  update public.families set settings = p_settings where id = fid;
end;
$$;
create function public.rotate_invite() returns text
language plpgsql security definer set search_path = '' as $$
declare result text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  update public.families set invite_code = upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)) where owner_id = auth.uid() returning invite_code into result;
  if result is null then raise exception 'Only the family owner can replace the invite code'; end if;
  return result;
end;
$$;

revoke all on public.families, public.memberships, public.deliveries, public.payments from anon, authenticated;
grant select on public.families, public.memberships to authenticated;
grant select, insert, update, delete on public.deliveries to authenticated;
grant select, insert, delete on public.payments to authenticated;
revoke all on function private.is_family_member(uuid), private.is_family_owner(uuid), public.create_family(text,text), public.join_family(text,text), public.update_family_settings(jsonb), public.rotate_invite() from public, anon;
grant execute on function private.is_family_member(uuid), private.is_family_owner(uuid), public.create_family(text,text), public.join_family(text,text), public.update_family_settings(jsonb), public.rotate_invite() to authenticated;
commit;
