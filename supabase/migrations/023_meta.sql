-- 022_meta.sql
--
-- Schema-version handshake. A self-hosted server may lag behind the app: a
-- user updates FamilyFocal on their phone but forgets to apply new migrations
-- on their box. Without a signal the app fails in confusing ways. This gives
-- the app one cheap, auth-free read to compare against the schema version it
-- needs, so it can show "your sync server is out of date — apply migrations"
-- instead of cryptic 4xx/PGRST errors.
--
-- The app reads it via PostgREST:
--   GET /rest/v1/meta?select=schema_version   (Accept-Profile: familyfocal)
--
-- familyfocal.meta is a singleton (one row, enforced). RLS is enabled (every
-- familyfocal table must have it), with a read-everyone policy — the version
-- is public and carries no family data, and the app must be able to read it
-- before it has a session.
--
-- Bumping the version: this is a monotonic integer. By convention it tracks
-- the highest migration that changed the *app-facing* contract. When a future
-- migration adds schema the app will depend on, bump it in that same migration:
--   update familyfocal.meta set schema_version = <n>;
-- (Pure RLS/policy tweaks that don't change the app contract need no bump.)

create table familyfocal.meta (
  id             boolean primary key default true,
  schema_version integer not null,
  updated_at     timestamptz not null default now(),
  -- singleton guard: only the row with id = true may ever exist
  constraint meta_singleton check (id = true)
);

create trigger meta_set_updated_at
  before update on familyfocal.meta
  for each row execute function familyfocal.set_updated_at();

-- schema_version tracks the app-facing DATA contract — the highest migration
-- the app depends on for reading/writing rows. That is currently 22
-- (022_tasks_recurrence). meta itself (023) and other infra-only migrations do
-- NOT bump it: the app reads meta to learn the version, so meta can't be part
-- of the version it advertises.
insert into familyfocal.meta (id, schema_version) values (true, 22);

alter table familyfocal.meta enable row level security;

-- Read-everyone: anon (pre-login version check) and authenticated. No insert/
-- update/delete policies — only migrations (service role / postgres) change it.
create policy meta_select_all
  on familyfocal.meta
  for select
  to anon, authenticated
  using (true);

-- Explicit SELECT grant so the handshake keeps working even after the broad
-- "grant all ... to anon" default privileges get tightened (see plan, P0).
grant select on familyfocal.meta to anon, authenticated;
