-- 009_realtime_phase6.sql
--
-- Phase 6 step 4 of 4: opt the three new tables into supabase_realtime
-- so the per-entity EntitySyncController on each client receives
-- postgres_changes events and debounces a syncNow() pass when a sibling
-- device edits something. Mirrors 004_realtime_publication.sql; same
-- idempotent guard so re-runs are safe.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname    = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename  = 'task_categories'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.task_categories';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname    = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename  = 'child_accounts'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.child_accounts';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname    = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename  = 'tasks'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.tasks';
  end if;
end $$;
