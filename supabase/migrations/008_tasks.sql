-- 008_tasks.sql
--
-- Phase 6 step 3 of 4: tasks — chores / rewards / penalties. Mirrors the
-- Drift schema in familyfocal/lib/db/tables/tasks.dart. All FKs except
-- family_id are nullable so a row can keep existing locally even after
-- (say) its category gets deleted on another device.
--
-- The legacy text column `category` survives alongside the modern
-- `category_id` because the Drift schema still writes both; cleanup
-- belongs to a later polish pass.
--
-- RLS:
--   SELECT — parent (family-wide) OR kid where assignee_profile_id = self.
--   UPDATE — same (parent or assignee). Per the Phase 6 RLS decision
--            (2026-05-15), kids can rewrite any column on their own
--            tasks; the app UI restricts which fields are editable.
--            If reward/title manipulation becomes a concern, a later
--            BEFORE-UPDATE trigger can lock specific columns for kids.
--   INSERT — parent only.
--   DELETE — parent only.

create table familyfocal.tasks (
  id                    uuid primary key,
  family_id             uuid not null references familyfocal.families(id) on delete cascade,
  assignee_profile_id   uuid references familyfocal.profiles(id) on delete set null,
  category              text,
  category_id           uuid references familyfocal.task_categories(id) on delete set null,
  penalty_account_id    uuid references familyfocal.child_accounts(id) on delete set null,
  reward_account_id     uuid references familyfocal.child_accounts(id) on delete set null,
  title                 text not null,
  description           text,
  status                text not null default 'open'
                          check (status in ('open', 'in_progress', 'submitted',
                                            'confirmed', 'rejected', 'missed')),
  recurrence            text check (recurrence in ('daily', 'weekly', 'flexible')),
  difficulty            text check (difficulty in ('easy', 'medium', 'hard')),
  estimated_minutes     integer,
  due_date              timestamptz,
  confirmed_at          timestamptz,
  importance            integer not null default 5,
  urgency               integer not null default 5,
  penalty_points        integer,
  penalty_applied       boolean not null default false,
  reward_amount         integer,
  requires_approval     boolean not null default true,
  is_template           boolean not null default false,
  origin_instance       text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted               boolean not null default false
);

create index tasks_family_id_idx on familyfocal.tasks (family_id);
create index tasks_assignee_profile_id_idx on familyfocal.tasks (assignee_profile_id);
create index tasks_category_id_idx on familyfocal.tasks (category_id);
create index tasks_status_idx on familyfocal.tasks (status);

create trigger tasks_set_updated_at
  before update on familyfocal.tasks
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.tasks enable row level security;

create policy tasks_select_self_or_parent
  on familyfocal.tasks
  for select
  to authenticated
  using (
    assignee_profile_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy tasks_update_self_or_parent
  on familyfocal.tasks
  for update
  to authenticated
  using (
    assignee_profile_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  )
  with check (
    assignee_profile_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy tasks_insert_parent
  on familyfocal.tasks
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy tasks_delete_parent
  on familyfocal.tasks
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );
