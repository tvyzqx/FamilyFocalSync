-- 001_initial_schema.sql
--
-- Phase 1 of the FamilyFocal sync rollout. Creates the two core tables
-- families and profiles in the dedicated familyfocal schema (ADR-8).
--
-- Prerequisites (P1.0, applied manually by the server admin once):
--   create schema if not exists familyfocal;
--   plus usage + default privileges for anon, authenticated, service_role.
--
-- This migration assumes the schema exists. RLS policies live in
-- 002_rls_policies.sql.

-- updated_at maintenance --------------------------------------------------
--
-- LWW conflict resolution downstream (profile sync, entity sync) relies on
-- updated_at being monotonic on UPDATE. We don't trust clients to set it,
-- so a trigger does it server-side. Defined once, reused across tables.

create or replace function familyfocal.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- families ----------------------------------------------------------------

create table familyfocal.families (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_by  uuid not null references auth.users(id) on delete restrict,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index families_created_by_idx on familyfocal.families (created_by);

create trigger families_set_updated_at
  before update on familyfocal.families
  for each row execute function familyfocal.set_updated_at();

-- profiles ----------------------------------------------------------------

create table familyfocal.profiles (
  id                  uuid primary key default gen_random_uuid(),
  family_id           uuid not null references familyfocal.families(id) on delete cascade,
  user_id             uuid references auth.users(id) on delete set null,
  role                text not null check (role in ('parent', 'child', 'guest', 'godchild')),
  name                text not null,
  nickname            text,
  birth_date          date,
  avatar_emoji        text,
  avatar_image_path   text,
  can_see_balance     boolean not null default false,
  can_see_history     boolean not null default false,
  can_see_siblings    boolean not null default false,
  origin_instance     text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted             boolean not null default false
);

create index profiles_family_id_idx on familyfocal.profiles (family_id);
create index profiles_user_id_idx on familyfocal.profiles (user_id);

-- ADR-1: a single supabase user maps to at most one profile. Partial index
-- ignores rows where user_id is null (preassigned profiles waiting for a
-- claim).
create unique index profiles_user_id_unique
  on familyfocal.profiles (user_id)
  where user_id is not null;

create trigger profiles_set_updated_at
  before update on familyfocal.profiles
  for each row execute function familyfocal.set_updated_at();
