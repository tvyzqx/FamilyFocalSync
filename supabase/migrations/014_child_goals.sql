-- 014_child_goals.sql
--
-- Phase 6 Sub-Block 2 extension. General per-child goals. Different
-- from savings_goals — these are free-form goals that can optionally
-- be auto-completed when a linked task is confirmed or when a linked
-- account balance reaches threshold_amount.
--
-- Drift schema in lib/db/tables/child_goals.dart. The link_type
-- discriminator says how to interpret linked_task_id /
-- linked_account_id / threshold_amount:
--   null                  no auto-completion
--   'task'                completed when linked_task_id confirms
--   'account_threshold'   completed when linked_account_id balance
--                         reaches threshold_amount
--
-- FKs on linked_task_id / linked_account_id use ON DELETE SET NULL so
-- removing the target row leaves the goal alive but unlinked.
--
-- RLS:
--   SELECT — kid sees own (profile_id = auth_profile_id()),
--            parent sees the family.
--   INSERT / UPDATE / DELETE — parent only. If kid-set goals become
--            UI-relevant later, relax UPDATE to assignee-based.

create table familyfocal.child_goals (
  id                    uuid primary key,
  family_id             uuid not null references familyfocal.families(id) on delete cascade,
  profile_id            uuid not null references familyfocal.profiles(id) on delete cascade,
  title                 text not null,
  description           text,
  is_completed          boolean not null default false,
  completed_at          timestamptz,
  link_type             text check (link_type in ('task', 'account_threshold')),
  linked_task_id        uuid references familyfocal.tasks(id) on delete set null,
  linked_account_id     uuid references familyfocal.child_accounts(id) on delete set null,
  threshold_amount      integer,
  sort_order            integer not null default 0,
  origin_instance       text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted               boolean not null default false
);

create index child_goals_family_id_idx on familyfocal.child_goals (family_id);
create index child_goals_profile_id_idx on familyfocal.child_goals (profile_id);
create index child_goals_linked_task_id_idx on familyfocal.child_goals (linked_task_id);
create index child_goals_linked_account_id_idx on familyfocal.child_goals (linked_account_id);

create trigger child_goals_set_updated_at
  before update on familyfocal.child_goals
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.child_goals enable row level security;

create policy child_goals_select_self_or_parent
  on familyfocal.child_goals
  for select
  to authenticated
  using (
    profile_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy child_goals_insert_parent
  on familyfocal.child_goals
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy child_goals_update_parent
  on familyfocal.child_goals
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

create policy child_goals_delete_parent
  on familyfocal.child_goals
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

-- Add to realtime publication (idempotent).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname    = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename  = 'child_goals'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.child_goals';
  end if;
end $$;
