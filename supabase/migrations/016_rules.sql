-- 016_rules.sql
--
-- Phase 6 sub-block 3 — entry 2 of 4: rule_categories, rules, and
-- rule_acknowledgements. Mirrors lib/db/tables/rule_categories.dart,
-- rules.dart, rule_acknowledgements.dart.
--
-- Rules are family-wide info: every member (parent + kid) reads them,
-- writes are parent-only. Acknowledgements are the inverse: kids
-- write rows for themselves (when they hit "I read this rule"),
-- parents see all of them.
--
-- target_member_ids on rules stays text (comma-joined UUIDs) to match
-- the Drift column and avoid a wire-format dance during sync. Future
-- cleanup can switch to a real uuid[] once the local schema follows.

-- rule_categories ---------------------------------------------------------

create table familyfocal.rule_categories (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  name            text not null,
  color           text not null,
  emoji           text not null,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index rule_categories_family_id_idx
  on familyfocal.rule_categories (family_id);

create trigger rule_categories_set_updated_at
  before update on familyfocal.rule_categories
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.rule_categories enable row level security;

create policy rule_categories_select_family
  on familyfocal.rule_categories
  for select
  to authenticated
  using (family_id = familyfocal.auth_family_id());

create policy rule_categories_insert_parent
  on familyfocal.rule_categories
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy rule_categories_update_parent
  on familyfocal.rule_categories
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

create policy rule_categories_delete_parent
  on familyfocal.rule_categories
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

-- rules -------------------------------------------------------------------

create table familyfocal.rules (
  id                 uuid primary key,
  family_id          uuid not null references familyfocal.families(id) on delete cascade,
  title              text not null,
  description        text,
  category           text,
  category_id        uuid references familyfocal.rule_categories(id) on delete set null,
  target_member_ids  text,
  origin_instance    text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted            boolean not null default false
);

create index rules_family_id_idx on familyfocal.rules (family_id);
create index rules_category_id_idx on familyfocal.rules (category_id);

create trigger rules_set_updated_at
  before update on familyfocal.rules
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.rules enable row level security;

create policy rules_select_family
  on familyfocal.rules
  for select
  to authenticated
  using (family_id = familyfocal.auth_family_id());

create policy rules_insert_parent
  on familyfocal.rules
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy rules_update_parent
  on familyfocal.rules
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

create policy rules_delete_parent
  on familyfocal.rules
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

-- rule_acknowledgements ---------------------------------------------------
--
-- Kid writes an ack-row for themselves when they confirm a rule. Parent
-- sees the whole family's acks. UPDATE is allowed for self/parent
-- because the acknowledgedAt timestamp can change if the kid re-acks
-- after a rule was edited.

create table familyfocal.rule_acknowledgements (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  rule_id         uuid not null references familyfocal.rules(id) on delete cascade,
  member_id       uuid not null references familyfocal.profiles(id) on delete cascade,
  acknowledged_at timestamptz not null,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index rule_acknowledgements_family_id_idx
  on familyfocal.rule_acknowledgements (family_id);
create index rule_acknowledgements_rule_id_idx
  on familyfocal.rule_acknowledgements (rule_id);
create index rule_acknowledgements_member_id_idx
  on familyfocal.rule_acknowledgements (member_id);

create trigger rule_acknowledgements_set_updated_at
  before update on familyfocal.rule_acknowledgements
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.rule_acknowledgements enable row level security;

create policy rule_acknowledgements_select_self_or_parent
  on familyfocal.rule_acknowledgements
  for select
  to authenticated
  using (
    member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy rule_acknowledgements_insert_self
  on familyfocal.rule_acknowledgements
  for insert
  to authenticated
  with check (
    family_id = familyfocal.auth_family_id()
    and (
      member_id = familyfocal.auth_profile_id()
      or familyfocal.auth_is_parent()
    )
  );

create policy rule_acknowledgements_update_self_or_parent
  on familyfocal.rule_acknowledgements
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

create policy rule_acknowledgements_delete_self_or_parent
  on familyfocal.rule_acknowledgements
  for delete
  to authenticated
  using (
    member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

-- Realtime publication. Idempotent (matches 004 / 009 / 013 / 015).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename = 'rule_categories'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.rule_categories';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename = 'rules'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.rules';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename = 'rule_acknowledgements'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.rule_acknowledgements';
  end if;
end $$;
