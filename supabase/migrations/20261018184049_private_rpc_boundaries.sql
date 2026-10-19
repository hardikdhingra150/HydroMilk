begin;
-- Expose unprivileged API wrappers; keep privileged implementations private.
alter function public.create_family(text,text) set schema private;
create function public.create_family(p_name text, p_display_name text) returns uuid
language sql security invoker set search_path = '' as $$
  select private.create_family(p_name,p_display_name);
$$;
revoke all on function public.create_family(text,text) from public, anon;
grant execute on function public.create_family(text,text) to authenticated;
alter function public.join_family(text,text) set schema private;
create function public.join_family(p_code text, p_display_name text) returns uuid
language sql security invoker set search_path = '' as $$
  select private.join_family(p_code,p_display_name);
$$;
revoke all on function public.join_family(text,text) from public, anon;
grant execute on function public.join_family(text,text) to authenticated;
alter function public.update_family_settings(jsonb) set schema private;
create function public.update_family_settings(p_settings jsonb) returns void
language sql security invoker set search_path = '' as $$
  select private.update_family_settings(p_settings);
$$;
revoke all on function public.update_family_settings(jsonb) from public, anon;
grant execute on function public.update_family_settings(jsonb) to authenticated;
alter function public.rotate_invite() set schema private;
create function public.rotate_invite() returns text
language sql security invoker set search_path = '' as $$
  select private.rotate_invite();
$$;
revoke all on function public.rotate_invite() from public, anon;
grant execute on function public.rotate_invite() to authenticated;
alter function public.record_payment(uuid,text,date,date,integer,text) set schema private;
create function public.record_payment(p_id uuid, p_service text, p_month date, p_date date, p_amount integer, p_note text) returns void
language sql security invoker set search_path = '' as $$
  select private.record_payment(p_id,p_service,p_month,p_date,p_amount,p_note);
$$;
revoke all on function public.record_payment(uuid,text,date,date,integer,text) from public, anon;
grant execute on function public.record_payment(uuid,text,date,date,integer,text) to authenticated;
alter function public.remove_family_member(uuid) set schema private;
create function public.remove_family_member(p_user_id uuid) returns void
language sql security invoker set search_path = '' as $$
  select private.remove_family_member(p_user_id);
$$;
revoke all on function public.remove_family_member(uuid) from public, anon;
grant execute on function public.remove_family_member(uuid) to authenticated;
alter function public.leave_family() set schema private;
create function public.leave_family() returns void
language sql security invoker set search_path = '' as $$
  select private.leave_family();
$$;
revoke all on function public.leave_family() from public, anon;
grant execute on function public.leave_family() to authenticated;
notify pgrst, 'reload schema';
commit;
