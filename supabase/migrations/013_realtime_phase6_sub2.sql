-- 013_realtime_phase6_sub2.sql
--
-- Phase 6 Sub-Block 2 — entry 4 of 4. Add the three new tables to
-- the supabase_realtime publication so each EntitySyncController on
-- the client receives postgres_changes events. Mirrors the idempotent
-- DO-Block pattern from 004 and 009.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname    = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename  = 'development_entries'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.development_entries';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname    = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename  = 'child_preferences'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.child_preferences';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname    = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename  = 'savings_goals'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.savings_goals';
  end if;
end $$;
