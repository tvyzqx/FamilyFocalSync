-- 012_savings_goals.sql
--
-- Phase 6 Sub-Block 2 — entry 3 of 4. Per-child savings targets.
-- Drift stores target_amount_cents as real; mirror that exactly
-- (double precision) so a fractional cent value the client computed
-- doesn't round-trip badly. Currency is purely a display concern
-- handled by unitSettingsProvider — server stores cents.
--
-- RLS:
--   SELECT — kid sees own (profile_id = auth_profile_id()),
--            parent sees the whole family.
--   INSERT / UPDATE / DELETE — parent only. Parent sets the goal,
--            kid saves up toward it.

create table familyfocal.savings_goals (
  id                    uuid primary key,
  family_id             uuid not null references familyfocal.families(id) on delete cascade,
  profile_id            uuid not null references familyfocal.profiles(id) on delete cascade,
  title                 text not null,
  target_amount_cents   double precision not null,
  is_reached            boolean not null default false,
  origin_instance       text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted               boolean not null default false
);

create index savings_goals_family_id_idx on familyfocal.savings_goals (family_id);
create index savings_goals_profile_id_idx on familyfocal.savings_goals (profile_id);

create trigger savings_goals_set_updated_at
  before update on familyfocal.savings_goals
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.savings_goals enable row level security;

create policy savings_goals_select_self_or_parent
  on familyfocal.savings_goals
  for select
  to authenticated
  using (
    profile_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy savings_goals_insert_parent
  on familyfocal.savings_goals
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy savings_goals_update_parent
  on familyfocal.savings_goals
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

create policy savings_goals_delete_parent
  on familyfocal.savings_goals
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );
