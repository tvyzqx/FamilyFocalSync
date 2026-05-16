-- 007_child_accounts.sql
--
-- Phase 6 step 2 of 4: child_accounts — money / points / screen-time
-- balances per child. The Drift table calls the owner column member_id
-- and points at family_members.id; on the server that's profile_id (a
-- profiles.id uuid).
--
-- Also defines familyfocal.auth_profile_id() — the calling user's own
-- profile.id, used here for "kid sees their own accounts" and again in
-- 008_tasks.sql for "kid sees their own tasks". Same SECURITY DEFINER
-- pattern as auth_family_id() / auth_is_parent() in 002_rls_policies.sql.

create or replace function familyfocal.auth_profile_id()
returns uuid
language sql
security definer
stable
set search_path = familyfocal, pg_temp
as $$
  select id
    from familyfocal.profiles
   where user_id = auth.uid()
     and deleted = false
   limit 1;
$$;

grant execute on function familyfocal.auth_profile_id() to authenticated;

create table familyfocal.child_accounts (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  profile_id      uuid not null references familyfocal.profiles(id) on delete cascade,
  name            text not null,
  type            text not null check (type in ('money', 'points', 'screen_time')),
  is_visible      boolean not null default true,
  sort_order      integer not null default 0,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index child_accounts_family_id_idx on familyfocal.child_accounts (family_id);
create index child_accounts_profile_id_idx on familyfocal.child_accounts (profile_id);

create trigger child_accounts_set_updated_at
  before update on familyfocal.child_accounts
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.child_accounts enable row level security;

create policy child_accounts_select_self_or_parent
  on familyfocal.child_accounts
  for select
  to authenticated
  using (
    profile_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy child_accounts_insert_parent
  on familyfocal.child_accounts
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy child_accounts_update_parent
  on familyfocal.child_accounts
  for update
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  )
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy child_accounts_delete_parent
  on familyfocal.child_accounts
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );
