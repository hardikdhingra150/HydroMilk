begin;
-- A retry reuses the same payment ID; an uncertain network response cannot double-charge the ledger.
create function public.record_payment(p_id uuid, p_service text, p_month date, p_date date, p_amount integer, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare fid uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select family_id into fid from public.memberships where user_id = auth.uid();
  if fid is null then raise exception 'Join a family first'; end if;
  insert into public.payments(id, family_id, service, billing_month, date, amount_paise, note)
    values (p_id, fid, p_service, p_month, p_date, p_amount, p_note) on conflict (id) do nothing;
  if not exists(select 1 from public.payments where id = p_id and family_id = fid and service = p_service and billing_month = p_month and date = p_date and amount_paise = p_amount and note = p_note) then raise exception 'Payment ID already used'; end if;
end;
$$;
create function public.remove_family_member(p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare fid uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select id into fid from public.families where owner_id = auth.uid();
  if fid is null then raise exception 'Only the family owner can remove members'; end if;
  if p_user_id = auth.uid() then raise exception 'The owner cannot be removed'; end if;
  delete from public.memberships where family_id = fid and user_id = p_user_id and role = 'member';
end;
$$;
create function public.leave_family() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if exists(select 1 from public.memberships where user_id = auth.uid() and role = 'owner') then raise exception 'Owners must keep their family membership'; end if;
  delete from public.memberships where user_id = auth.uid();
end;
$$;
revoke all on function public.record_payment(uuid,text,date,date,integer,text), public.remove_family_member(uuid), public.leave_family() from public, anon;
grant execute on function public.record_payment(uuid,text,date,date,integer,text), public.remove_family_member(uuid), public.leave_family() to authenticated;
commit;
