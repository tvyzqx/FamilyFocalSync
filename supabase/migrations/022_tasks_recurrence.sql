-- 022_tasks_recurrence.sql
--
-- Recurring tasks: the app now lets parents configure how a task repeats
-- once it is completed (or its deadline is missed). Two new columns mirror
-- the Drift schema in familyfocal/lib/db/tables/tasks.dart:
--
--   recurrence_interval — "every N units" of the existing `recurrence`
--                         unit (daily/weekly). Null is treated as 1 by
--                         the app.
--   recurrence_mode     — how the next due date is derived:
--                           'fixed'   = advance the previous due date on a
--                                       schedule (e.g. every Monday).
--                           'dynamic' = N units after actual completion.
--                         Null falls back to a fixed schedule in the app.
--
-- Both are nullable; existing rows keep repeating exactly as before
-- (interval 1, fixed schedule). No RLS change — the existing
-- tasks_update_self_or_parent / tasks_insert_parent policies already
-- cover every column on the row.
--
-- Idempotent so re-running the migration is safe.

alter table familyfocal.tasks
  add column if not exists recurrence_interval integer;

alter table familyfocal.tasks
  add column if not exists recurrence_mode text;

alter table familyfocal.tasks
  drop constraint if exists tasks_recurrence_mode_check;

alter table familyfocal.tasks
  add constraint tasks_recurrence_mode_check
  check (recurrence_mode is null or recurrence_mode in ('fixed', 'dynamic'));
