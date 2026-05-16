-- 006_task_categories.sql
--
-- Phase 6 step 1 of 4: task_categories — the family-wide pool of
-- category metadata (name, color, emoji) referenced by tasks.category_id.
--
-- RLS:
--   SELECT — every family member, including kids, so they can render
--            category labels on their own task list.
--   INSERT / UPDATE / DELETE — parent only, in their own family.

create table familyfocal.task_categories (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  name            text not null,
  color           text not null,
  emoji           text not null,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index task_categories_family_id_idx on familyfocal.task_categories (family_id);

create trigger task_categories_set_updated_at
  before update on familyfocal.task_categories
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.task_categories enable row level security;

create policy task_categories_select_family
  on familyfocal.task_categories
  for select
  to authenticated
  using (family_id = familyfocal.auth_family_id());

create policy task_categories_insert_parent
  on familyfocal.task_categories
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy task_categories_update_parent
  on familyfocal.task_categories
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

create policy task_categories_delete_parent
  on familyfocal.task_categories
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );
