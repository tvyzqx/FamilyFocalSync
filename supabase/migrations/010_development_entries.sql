-- 010_development_entries.sql
--
-- Phase 6 Sub-Block 2 — entry 1 of 4. Per-child development data:
-- height_cm, weight_kg, shoe_size, clothing_size, milestone, highlight.
-- The Drift schema in lib/db/tables/development_entries.dart stores
-- both measurements and free-form milestones in the same table; the
-- `type` column discriminates and `value` is the serialized payload
-- (a number for sizes, free text for milestones / highlights).
--
-- Units are handled entirely in the app via unitSettingsProvider —
-- the server stores raw values exactly as the client sent them. No
-- unit conversion on the server.
--
-- RLS:
--   SELECT — kid sees own (profile_id = auth_profile_id()),
--            parent sees the whole family.
--   INSERT / UPDATE / DELETE — parent only. Kids don't measure
--            themselves; parent enters values. UI doesn't expose
--            development entries to kids today.

create table familyfocal.development_entries (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  profile_id      uuid not null references familyfocal.profiles(id) on delete cascade,
  type            text not null check (type in (
                    'height_cm', 'weight_kg', 'shoe_size',
                    'clothing_size', 'milestone', 'highlight'
                  )),
  value           text not null,
  note            text,
  recorded_at     timestamptz not null,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index development_entries_family_id_idx on familyfocal.development_entries (family_id);
create index development_entries_profile_id_idx on familyfocal.development_entries (profile_id);
create index development_entries_type_idx on familyfocal.development_entries (type);

create trigger development_entries_set_updated_at
  before update on familyfocal.development_entries
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.development_entries enable row level security;

create policy development_entries_select_self_or_parent
  on familyfocal.development_entries
  for select
  to authenticated
  using (
    profile_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy development_entries_insert_parent
  on familyfocal.development_entries
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy development_entries_update_parent
  on familyfocal.development_entries
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

create policy development_entries_delete_parent
  on familyfocal.development_entries
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );
