-- New families start with no assumed supplier prices or budget.
-- Existing family settings, deliveries, payments, and function privileges are preserved.
create or replace function private.create_family(p_name text, p_display_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare fid uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if length(trim(p_name)) not between 1 and 60 or length(trim(p_display_name)) not between 1 and 60 then raise exception 'Names must contain 1–60 characters'; end if;
  if exists(select 1 from public.memberships where user_id = auth.uid()) then raise exception 'You already belong to a family'; end if;
  insert into public.families(owner_id, settings) values (auth.uid(), jsonb_build_object('name', trim(p_name), 'currency', 'INR', 'milk_supplier', 'Milk supplier', 'water_supplier', 'Water supplier', 'milk_rate', 0, 'water_rate', 0, 'milk_quantity', 1000, 'water_quantity', 1000, 'budget', 0)) returning id into fid;
  insert into public.memberships(user_id, family_id, display_name, role) values(auth.uid(), fid, trim(p_display_name), 'owner');
  return fid;
end;
$$;
