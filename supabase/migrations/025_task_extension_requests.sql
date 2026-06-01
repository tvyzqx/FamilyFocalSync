-- 025_task_extension_requests.sql
--
-- A child asks for more time on a task they missed; a parent approves or
-- rejects. Until now this table lived only in the app's local Drift cache,
-- so the request never reached the parent's device. This mirrors
-- lib/db/tables/task_extension_requests.dart onto the server so it syncs
-- like every other entity.
--
-- RLS (mirrors mood_entries / rule_acknowledgements self-or-parent shape):
--   SELECT  — requester sees own (requested_by_id = self), parent sees
--             family-wide (to review).
--   INSERT  — requester for self, or parent on behalf. family_id must match.
--   UPDATE  — parent reviews (approve/reject); requester may amend their own
--             still-pending request. Follows SELECT scope.
--   DELETE  — requester or parent, in-family.
--
-- schema_version is NOT bumped: the app treats this sync as additive and
-- isolates a missing-table error to this one entity (the rest keeps syncing
-- against an older server). Apply this migration to enable the feature.

create table familyfocal.task_extension_requests (
  id               uuid primary key,
  family_id        uuid not null references familyfocal.families(id) on delete cascade,
  task_id          uuid not null references familyfocal.tasks(id) on delete cascade,
  requested_by_id  uuid not null references familyfocal.profiles(id) on delete cascade,
  requested_at     timestamptz not null,
  reason           text,
  new_due_date     timestamptz not null,
  status           text not null default 'pending',
  reviewed_at      timestamptz,
  reviewed_by_id   uuid references familyfocal.profiles(id) on delete set null,
  origin_instance  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted          boolean not null default false
);

create index task_extension_requests_family_id_idx
  on familyfocal.task_extension_requests (family_id);
create index task_extension_requests_task_id_idx
  on familyfocal.task_extension_requests (task_id);
create index task_extension_requests_requested_by_id_idx
  on familyfocal.task_extension_requests (requested_by_id);

create trigger task_extension_requests_set_updated_at
  before update on familyfocal.task_extension_requests
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.task_extension_requests enable row level security;

create policy task_extension_requests_select_self_or_parent
  on familyfocal.task_extension_requests
  for select
  to authenticated
  using (
    requested_by_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy task_extension_requests_insert_self_or_parent
  on familyfocal.task_extension_requests
  for insert
  to authenticated
  with check (
    family_id = familyfocal.auth_family_id()
    and (
      requested_by_id = familyfocal.auth_profile_id()
      or familyfocal.auth_is_parent()
    )
  );

create policy task_extension_requests_update_self_or_parent
  on familyfocal.task_extension_requests
  for update
  to authenticated
  using (
    requested_by_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  )
  with check (
    requested_by_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy task_extension_requests_delete_self_or_parent
  on familyfocal.task_extension_requests
  for delete
  to authenticated
  using (
    requested_by_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename = 'task_extension_requests'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.task_extension_requests';
  end if;
end $$;
