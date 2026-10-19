\set ON_ERROR_STOP on
begin;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
select public.create_family('Peach home', 'Owner') as family_a \gset
do $$ begin
  if (select (settings->>'milk_rate')::int from public.families) != 0
     or (select (settings->>'water_rate')::int from public.families) != 0
     or (select (settings->>'budget')::int from public.families) != 0 then
    raise exception 'New family contains predefined prices or budget';
  end if;
  if (select count(*) from public.deliveries) != 0 or (select count(*) from public.payments) != 0 then
    raise exception 'New family contains sample transactions';
  end if;
end $$;
select invite_code as code_a from public.families \gset
insert into public.deliveries(id, family_id, service, date, quantity_milli, rate_paise) values ('11111111-1111-1111-1111-111111111111', :'family_a', 'milk', '2024-02-29', 1500, 6250);
do $$ begin
  if (select amount_paise from public.deliveries limit 1) != 9375 then raise exception 'Rounding failed'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
select public.create_family('Other home', 'Outsider') as family_b \gset
do $$ begin
  if (select count(*) from public.deliveries) != 0 then raise exception 'Leaked another family delivery'; end if;
  if (select count(*) from public.families) != 1 then raise exception 'Leaked family details'; end if;
end $$;
-- Copying a family ID must not grant insert access.
select set_config('test.family_a', :'family_a', false);
do $$ begin
  begin
    insert into public.deliveries(id, family_id, service, date, quantity_milli, rate_paise) values (gen_random_uuid(), current_setting('test.family_a')::uuid, 'milk', '2024-02-29', 1000, 6000);
    raise exception 'Cross-family insert unexpectedly succeeded';
  exception when insufficient_privilege then null; end;
  update public.deliveries set rate_paise = 1;
  if found then raise exception 'Cross-family update succeeded'; end if;
  delete from public.deliveries;
  if found then raise exception 'Cross-family delete succeeded'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', false);
select public.join_family(:'code_a', 'Family member');
do $$ begin
  if (select count(*) from public.deliveries) != 1 then raise exception 'Member cannot read family'; end if;
  if (select count(*) from public.memberships) != 2 then raise exception 'Member list incorrect'; end if;
  begin perform public.rotate_invite(); raise exception 'Member rotated invite'; exception when raise_exception then if sqlerrm = 'Member rotated invite' then raise; end if; end;
end $$;
update public.deliveries set status = 'skipped';
do $$ begin if (select sum(amount_paise) from public.deliveries) != 0 then raise exception 'Skipped delivery charged'; end if; end $$;
insert into public.payments(id, family_id, service, billing_month, date, amount_paise) values (gen_random_uuid(), :'family_a', 'milk', '2024-02-01', '2024-03-02', 3000);
do $$ begin
  begin insert into public.payments(id, family_id, service, billing_month, date, amount_paise) select gen_random_uuid(), family_id, 'milk', '2024-02-15', '2024-03-02', 3000 from public.memberships limit 1; raise exception 'Invalid month accepted'; exception when check_violation then null; end;
  begin perform public.update_family_settings('{}'); raise exception 'Invalid settings accepted'; exception when raise_exception then if sqlerrm = 'Invalid settings accepted' then raise; end if; end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
select public.record_payment('99999999-9999-9999-9999-999999999999', 'milk', '2024-02-01', '2024-03-02', 2000, 'Cash');
select public.record_payment('99999999-9999-9999-9999-999999999999', 'milk', '2024-02-01', '2024-03-02', 2000, 'Cash');
do $$ begin if (select count(*) from public.payments where id = '99999999-9999-9999-9999-999999999999') != 1 then raise exception 'Payment retry duplicated'; end if; end $$;
select public.rotate_invite();
select public.remove_family_member('00000000-0000-0000-0000-000000000003');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', false);
do $$ begin if (select count(*) from public.deliveries) != 0 then raise exception 'Removed member retained access'; end if; end $$;
select set_config('request.jwt.claim.sub', '', false);
do $$ begin
  if (select count(*) from public.deliveries) != 0 then raise exception 'Unauthenticated delivery access'; end if;
  begin perform public.create_family('bad', 'bad'); raise exception 'Unauthenticated family created'; exception when raise_exception then if sqlerrm = 'Unauthenticated family created' then raise; end if; end;
end $$;
rollback;
\echo 'PASS: rounding, skipped charges, household isolation, membership, role checks, input validation, and unauthenticated access'
