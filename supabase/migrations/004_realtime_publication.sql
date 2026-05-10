-- 004_realtime_publication.sql
--
-- Realtime needs each table that should broadcast postgres changes to be
-- listed in the supabase_realtime publication. The publication's default
-- definition does not include the familyfocal schema — without this
-- migration, Realtime subscribers on familyfocal.* tables would never
-- receive events even though Realtime itself is healthy.
--
-- Only profiles is added here: families changes rarely and from one
-- device, join_tokens is polled via check-join-status. Phase 6 adds the
-- entity tables (tasks, allowance, …) the same way.
--
-- Idempotent: re-applying this migration is a no-op.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname    = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename  = 'profiles'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.profiles';
  end if;
end $$;
