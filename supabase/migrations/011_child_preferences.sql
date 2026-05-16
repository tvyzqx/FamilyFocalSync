-- 011_child_preferences.sql
--
-- Phase 6 Sub-Block 2 — entry 2 of 4. Per-child preferences: favorite
-- and nogo foods, colors, clothing items, interests. The Drift schema
-- in lib/db/tables/child_preferences.dart uses `is_nogo` as a flag —
-- only meaningful for `food` today (favorite vs. dislike); other
-- categories ignore it.
--
-- RLS:
--   SELECT — kid sees own (profile_id = auth_profile_id()),
--            parent sees the whole family.
--   INSERT / UPDATE / DELETE — parent only. If a kid-facing UI for
--            editing own preferences lands later, relax UPDATE to
--            assignee-based (analog tasks UPDATE policy) and use
--            .update().eq('id', …) on the client side.

create table familyfocal.child_preferences (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  profile_id      uuid not null references familyfocal.profiles(id) on delete cascade,
  category        text not null check (category in (
                    'food', 'color', 'clothing', 'interest'
                  )),
  label           text not null,
  is_nogo         boolean not null default false,
  recorded_at     timestamptz not null,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index child_preferences_family_id_idx on familyfocal.child_preferences (family_id);
create index child_preferences_profile_id_idx on familyfocal.child_preferences (profile_id);
create index child_preferences_category_idx on familyfocal.child_preferences (category);

create trigger child_preferences_set_updated_at
  before update on familyfocal.child_preferences
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.child_preferences enable row level security;

create policy child_preferences_select_self_or_parent
  on familyfocal.child_preferences
  for select
  to authenticated
  using (
    profile_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy child_preferences_insert_parent
  on familyfocal.child_preferences
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy child_preferences_update_parent
  on familyfocal.child_preferences
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

create policy child_preferences_delete_parent
  on familyfocal.child_preferences
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );
