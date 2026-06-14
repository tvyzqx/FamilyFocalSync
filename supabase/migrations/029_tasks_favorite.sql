-- 029_tasks_favorite.sql
--
-- Favorite task templates. The app's template picker surfaces favorited
-- templates in a "Favorites" group at the top of the list so a long
-- template set stays quick to navigate. This mirrors the new
-- `is_favorite` column on the Drift schema in
-- familyfocal/lib/db/tables/tasks.dart.
--
-- The flag is only meaningful on template rows (is_template = true), but
-- it lives on `tasks` like every other template attribute — a template
-- is just a task with is_template = true.
--
-- NOT NULL DEFAULT false: existing rows become "not favorited", and old
-- clients that omit the column on INSERT still succeed (the default
-- fills in). This keeps the additive-only migration contract
-- (scripts/check_migrations.py) satisfied.
--
-- No RLS change — the existing tasks_select_* / tasks_update_self_or_parent
-- / tasks_insert_parent policies already cover every column on the row.
--
-- schema_version IS bumped to 29. Unlike the 025–027 sub-table syncs (which
-- live on isolated tables, so a missing one only disables that one feature),
-- is_favorite is a column on `tasks`, which the app reads in its select set
-- and writes on every task push. Against a server without this column those
-- reads/writes would 400 the whole tasks sync, so the app must treat it as a
-- hard contract: kRequiredSchemaVersion in the app is bumped to 29 to match,
-- and the schema handshake keeps the app offline-only (never partially
-- writing) until the server is upgraded — same approach as 022_tasks_recurrence.
--
-- Idempotent so re-running the migration is safe.

alter table familyfocal.tasks
  add column if not exists is_favorite boolean not null default false;

-- The app now depends on this column for reading/writing task rows; advertise
-- it so older self-hosted servers report "out of date" instead of 400ing.
update familyfocal.meta set schema_version = 29;
