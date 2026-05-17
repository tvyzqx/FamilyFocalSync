-- 019_mood_entries.sql
--
-- Phase 6 sub-block 3 — entry 5: mood_entries (kid daily mood log).
-- Mirrors lib/db/tables/mood_entries.dart row-for-row.
--
-- One row per kid per day in practice (the client's upsertTodayMood
-- collapses by day on insert). Server keeps the row-per-id model so
-- the same id round-trips through sync without re-keying logic.
--
-- RLS: kid writes for self, parent reads family-wide for the
-- emotional-check-in dashboard. UPDATE follows SELECT — kid can
-- change their own entry (the UI lets them tweak today's mood),
-- parent can amend a kid's entry (e.g. add a note from a
-- conversation later). DELETE is parent-or-self so cleanup works on
-- either side.

create table familyfocal.mood_entries (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  member_id       uuid not null references familyfocal.profiles(id) on delete cascade,
  mood            text not null,
  note            text,
  recorded_at     timestamptz not null,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index mood_entries_family_id_idx on familyfocal.mood_entries (family_id);
create index mood_entries_member_id_idx on familyfocal.mood_entries (member_id);
create index mood_entries_recorded_at_idx on familyfocal.mood_entries (recorded_at);

create trigger mood_entries_set_updated_at
  before update on familyfocal.mood_entries
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.mood_entries enable row level security;

create policy mood_entries_select_self_or_parent
  on familyfocal.mood_entries
  for select
  to authenticated
  using (
    member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy mood_entries_insert_self
  on familyfocal.mood_entries
  for insert
  to authenticated
  with check (
    family_id = familyfocal.auth_family_id()
    and (
      member_id = familyfocal.auth_profile_id()
      or familyfocal.auth_is_parent()
    )
  );

create policy mood_entries_update_self_or_parent
  on familyfocal.mood_entries
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

create policy mood_entries_delete_self_or_parent
  on familyfocal.mood_entries
  for delete
  to authenticated
  using (
    member_id = familyfocal.auth_profile_id()
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
       and tablename = 'mood_entries'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.mood_entries';
  end if;
end $$;
