-- 015_allowance_entries.sql
--
-- Phase 6 sub-block 3 — entry 1 of 4 (allowance / rules / gifts /
-- council). Mirrors lib/db/tables/allowance_entries.dart.
--
-- One row = one credit or debit posting against a child_account.
-- Amount lives in cents stored as `real` to match the Drift column;
-- could narrow to bigint cents later if anyone hits precision issues.
--
-- RLS shape mirrors 008_tasks.sql: parent sees the whole family, kid
-- sees rows where member_id is their own profile. Writes are
-- parent-only in the UI today, but the policy lets the kid touch
-- their own row in principle so future "kid corrects a typo on a
-- pending booking" flows don't need a policy change.

create table familyfocal.allowance_entries (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  member_id       uuid not null references familyfocal.profiles(id) on delete cascade,
  account_id      uuid references familyfocal.child_accounts(id) on delete set null,
  amount_cents    real not null,
  type            text not null check (type in ('credit', 'debit')),
  note            text,
  related_task_id uuid references familyfocal.tasks(id) on delete set null,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index allowance_entries_family_id_idx
  on familyfocal.allowance_entries (family_id);
create index allowance_entries_member_id_idx
  on familyfocal.allowance_entries (member_id);
create index allowance_entries_account_id_idx
  on familyfocal.allowance_entries (account_id);
create index allowance_entries_related_task_id_idx
  on familyfocal.allowance_entries (related_task_id);

create trigger allowance_entries_set_updated_at
  before update on familyfocal.allowance_entries
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.allowance_entries enable row level security;

create policy allowance_entries_select_self_or_parent
  on familyfocal.allowance_entries
  for select
  to authenticated
  using (
    member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy allowance_entries_update_self_or_parent
  on familyfocal.allowance_entries
  for update
  to authenticated
  using (
    member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  )
  with check (
    member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy allowance_entries_insert_parent
  on familyfocal.allowance_entries
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy allowance_entries_delete_parent
  on familyfocal.allowance_entries
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

-- Realtime publication. Idempotent (matches 004 / 009 / 013 pattern).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname    = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename  = 'allowance_entries'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.allowance_entries';
  end if;
end $$;
