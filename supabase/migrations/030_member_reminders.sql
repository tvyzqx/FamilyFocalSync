-- 030_member_reminders.sql
--
-- Per-member, parent-configured generic local reminders. The self-host
-- alternative to server push: a parent sets when a member's device should
-- pop a generic "open the app and check your tasks" local notification, and
-- the row syncs to that member's device, where the app schedules it.
--
-- Drift schema: lib/db/tables/member_reminders.dart. Server `profile_id`
-- maps to Drift `member_id`. A member may have several reminders, so the row
-- is keyed by id, not by profile_id.
--
-- time_minutes: minutes since midnight (0..1439), local device time.
-- weekday_mask: Mon=1 .. Sun=64 (127 = every day), same convention as
--   media_rules.
--
-- RLS (mirrors child_preferences):
--   SELECT — member sees own (profile_id = auth_profile_id()),
--            parent sees the whole family.
--   INSERT / UPDATE / DELETE — parent only.

create table familyfocal.member_reminders (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  profile_id      uuid not null references familyfocal.profiles(id) on delete cascade,
  enabled         boolean not null default true,
  time_minutes    integer not null check (time_minutes between 0 and 1439),
  weekday_mask    integer not null default 127 check (weekday_mask between 0 and 127),
  label           text,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index member_reminders_family_id_idx on familyfocal.member_reminders (family_id);
create index member_reminders_profile_id_idx on familyfocal.member_reminders (profile_id);

create trigger member_reminders_set_updated_at
  before update on familyfocal.member_reminders
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.member_reminders enable row level security;

create policy member_reminders_select_self_or_parent
  on familyfocal.member_reminders
  for select
  to authenticated
  using (
    profile_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy member_reminders_insert_parent
  on familyfocal.member_reminders
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy member_reminders_update_parent
  on familyfocal.member_reminders
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

create policy member_reminders_delete_parent
  on familyfocal.member_reminders
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

-- Realtime so each member's device receives the parent's config changes.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname    = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename  = 'member_reminders'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.member_reminders';
  end if;
end $$;
