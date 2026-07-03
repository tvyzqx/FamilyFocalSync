-- 031_informations.sql
--
-- Infothek: shared family reference info (garbage collection times,
-- doctors, emergency contacts, public transport …). Mirrors
-- lib/db/tables/information_categories.dart and informations.dart.
--
-- Like rules, this is family-wide info: every member (parent + kid)
-- reads it, writes are parent-only. Unlike rules there are no
-- acknowledgements — info is reference material, not something kids
-- confirm.
--
-- The Drift `informations` table carries only `category_id` (no
-- denormalized `category` name column), so this table omits it too.
-- Structured optional fields phone/address/url stay text and power the
-- client's tap-to-call / open-in-maps / open-link actions.

-- information_categories ---------------------------------------------------

create table familyfocal.information_categories (
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

create index information_categories_family_id_idx
  on familyfocal.information_categories (family_id);

create trigger information_categories_set_updated_at
  before update on familyfocal.information_categories
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.information_categories enable row level security;

create policy information_categories_select_family
  on familyfocal.information_categories
  for select
  to authenticated
  using (family_id = familyfocal.auth_family_id());

create policy information_categories_insert_parent
  on familyfocal.information_categories
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy information_categories_update_parent
  on familyfocal.information_categories
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

create policy information_categories_delete_parent
  on familyfocal.information_categories
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

-- informations -------------------------------------------------------------

create table familyfocal.informations (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  title           text not null,
  note            text,
  category_id     uuid references familyfocal.information_categories(id) on delete set null,
  phone           text,
  address         text,
  url             text,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index informations_family_id_idx on familyfocal.informations (family_id);
create index informations_category_id_idx on familyfocal.informations (category_id);

create trigger informations_set_updated_at
  before update on familyfocal.informations
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.informations enable row level security;

create policy informations_select_family
  on familyfocal.informations
  for select
  to authenticated
  using (family_id = familyfocal.auth_family_id());

create policy informations_insert_parent
  on familyfocal.informations
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy informations_update_parent
  on familyfocal.informations
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

create policy informations_delete_parent
  on familyfocal.informations
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

-- Realtime publication. Idempotent (matches 004 / 009 / 013 / 015 / 016).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename = 'information_categories'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.information_categories';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename = 'informations'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.informations';
  end if;
end $$;
