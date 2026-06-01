-- 026_task_swap_requests.sql
--
-- A child asks a sibling to take over a task; the sibling accepts/declines,
-- and (optionally) a parent approves the swap. Until now this lived only in
-- the app's local Drift cache, so the request never reached the other child
-- or the parent. This mirrors lib/db/tables/task_swap_requests.dart onto the
-- server so it syncs.
--
-- RLS differs from the self-or-parent shape because a swap has TWO child
-- participants:
--   SELECT  — either party (from/to) or a parent in the family.
--   INSERT  — the requester (from_member_id = self) or a parent. family scoped.
--   UPDATE  — either party (the recipient responds, the requester can cancel)
--             or a parent (final approval). Follows SELECT scope.
--   DELETE  — requester or parent, in-family.
--
-- schema_version is NOT bumped: additive sync, the app isolates a
-- missing-table error to this one entity.

create table familyfocal.task_swap_requests (
  id                       uuid primary key,
  family_id                uuid not null references familyfocal.families(id) on delete cascade,
  task_id                  uuid not null references familyfocal.tasks(id) on delete cascade,
  from_member_id           uuid not null references familyfocal.profiles(id) on delete cascade,
  to_member_id             uuid not null references familyfocal.profiles(id) on delete cascade,
  status                   text not null default 'pending',
  requires_parent_approval boolean not null default true,
  origin_instance          text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  deleted                  boolean not null default false
);

create index task_swap_requests_family_id_idx
  on familyfocal.task_swap_requests (family_id);
create index task_swap_requests_task_id_idx
  on familyfocal.task_swap_requests (task_id);
create index task_swap_requests_from_member_id_idx
  on familyfocal.task_swap_requests (from_member_id);
create index task_swap_requests_to_member_id_idx
  on familyfocal.task_swap_requests (to_member_id);

create trigger task_swap_requests_set_updated_at
  before update on familyfocal.task_swap_requests
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.task_swap_requests enable row level security;

create policy task_swap_requests_select_party_or_parent
  on familyfocal.task_swap_requests
  for select
  to authenticated
  using (
    from_member_id = familyfocal.auth_profile_id()
    or to_member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy task_swap_requests_insert_requester_or_parent
  on familyfocal.task_swap_requests
  for insert
  to authenticated
  with check (
    family_id = familyfocal.auth_family_id()
    and (
      from_member_id = familyfocal.auth_profile_id()
      or familyfocal.auth_is_parent()
    )
  );

create policy task_swap_requests_update_party_or_parent
  on familyfocal.task_swap_requests
  for update
  to authenticated
  using (
    from_member_id = familyfocal.auth_profile_id()
    or to_member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  )
  with check (
    from_member_id = familyfocal.auth_profile_id()
    or to_member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy task_swap_requests_delete_requester_or_parent
  on familyfocal.task_swap_requests
  for delete
  to authenticated
  using (
    from_member_id = familyfocal.auth_profile_id()
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
       and tablename = 'task_swap_requests'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.task_swap_requests';
  end if;
end $$;
