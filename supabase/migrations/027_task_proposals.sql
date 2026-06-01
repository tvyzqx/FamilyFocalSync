-- 027_task_proposals.sql
--
-- A child proposes a new task ("can I earn money for washing the car?"); a
-- parent accepts (turning it into a task template) or rejects it. Until now
-- this lived only in the app's local Drift cache, so the proposal never
-- reached the parent. This mirrors lib/db/tables/task_proposals.dart onto the
-- server so it syncs.
--
-- RLS (self-or-parent, like mood_entries):
--   SELECT  — proposer sees own, parent sees family-wide to review.
--   INSERT  — proposer for self, or parent. family scoped.
--   UPDATE  — proposer may amend their own pending proposal; parent reviews.
--   DELETE  — proposer or parent, in-family.
--
-- schema_version is NOT bumped: additive sync, the app isolates a
-- missing-table error to this one entity.

create table familyfocal.task_proposals (
  id                    uuid primary key,
  family_id             uuid not null references familyfocal.families(id) on delete cascade,
  title                 text not null,
  description           text,
  proposed_by_member_id uuid not null references familyfocal.profiles(id) on delete cascade,
  reward_amount         integer,
  status                text not null default 'pending',
  reviewed_at           timestamptz,
  reviewed_by_id        uuid references familyfocal.profiles(id) on delete set null,
  rejection_reason      text,
  origin_instance       text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted               boolean not null default false
);

create index task_proposals_family_id_idx
  on familyfocal.task_proposals (family_id);
create index task_proposals_proposed_by_member_id_idx
  on familyfocal.task_proposals (proposed_by_member_id);

create trigger task_proposals_set_updated_at
  before update on familyfocal.task_proposals
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.task_proposals enable row level security;

create policy task_proposals_select_self_or_parent
  on familyfocal.task_proposals
  for select
  to authenticated
  using (
    proposed_by_member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy task_proposals_insert_self_or_parent
  on familyfocal.task_proposals
  for insert
  to authenticated
  with check (
    family_id = familyfocal.auth_family_id()
    and (
      proposed_by_member_id = familyfocal.auth_profile_id()
      or familyfocal.auth_is_parent()
    )
  );

create policy task_proposals_update_self_or_parent
  on familyfocal.task_proposals
  for update
  to authenticated
  using (
    proposed_by_member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  )
  with check (
    proposed_by_member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy task_proposals_delete_self_or_parent
  on familyfocal.task_proposals
  for delete
  to authenticated
  using (
    proposed_by_member_id = familyfocal.auth_profile_id()
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
       and tablename = 'task_proposals'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.task_proposals';
  end if;
end $$;
