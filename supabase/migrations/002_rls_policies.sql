-- 002_rls_policies.sql
--
-- Phase 1 RLS scoping (ADR-5: scope is enforced server-side, not client-
-- filtered). Two helper functions identify the caller's family and role
-- once per query so policies don't have to inline the same subquery.
--
-- The helpers must be SECURITY DEFINER. Otherwise any read of
-- familyfocal.profiles inside the helper would re-trigger profiles RLS,
-- which calls the helper, which reads profiles … → infinite recursion.
-- security definer makes the helpers run as the function owner (postgres),
-- bypassing RLS for the lookup. search_path is locked down to keep them
-- safe from search_path injection.

-- helpers -----------------------------------------------------------------

create or replace function familyfocal.auth_family_id()
returns uuid
language sql
security definer
stable
set search_path = familyfocal, pg_temp
as $$
  select family_id
    from familyfocal.profiles
   where user_id = auth.uid()
     and deleted = false
   limit 1;
$$;

create or replace function familyfocal.auth_is_parent()
returns boolean
language sql
security definer
stable
set search_path = familyfocal, pg_temp
as $$
  select exists (
    select 1
      from familyfocal.profiles
     where user_id = auth.uid()
       and role = 'parent'
       and deleted = false
  );
$$;

grant execute on function familyfocal.auth_family_id() to authenticated;
grant execute on function familyfocal.auth_is_parent() to authenticated;

-- families ---------------------------------------------------------------
--
-- INSERT and DELETE go through the bootstrap-family / delete-account edge
-- functions (service role, bypasses RLS). Only SELECT and UPDATE need
-- user-facing policies.

alter table familyfocal.families enable row level security;

create policy families_select_own
  on familyfocal.families
  for select
  to authenticated
  using (id = familyfocal.auth_family_id());

create policy families_update_parent
  on familyfocal.families
  for update
  to authenticated
  using (id = familyfocal.auth_family_id() and familyfocal.auth_is_parent())
  with check (id = familyfocal.auth_family_id() and familyfocal.auth_is_parent());

-- profiles ---------------------------------------------------------------
--
-- SELECT  : self (any role) OR parent in same family.
-- UPDATE  : same — children edit their own profile, parents edit anyone in
--           their family.
-- INSERT  : parents add new profiles to their own family. claim-profile /
--           join-family run as service role and bypass this policy.
-- DELETE  : parents only, in their own family. Soft delete via deleted=true
--           is the recommended path; hard delete is reserved for cleanup.

alter table familyfocal.profiles enable row level security;

create policy profiles_select_self_or_parent
  on familyfocal.profiles
  for select
  to authenticated
  using (
    user_id = auth.uid()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy profiles_update_self_or_parent
  on familyfocal.profiles
  for update
  to authenticated
  using (
    user_id = auth.uid()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  )
  with check (
    user_id = auth.uid()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy profiles_insert_parent
  on familyfocal.profiles
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy profiles_delete_parent
  on familyfocal.profiles
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );
