-- 017_gifts.sql
--
-- Phase 6 sub-block 3 — entry 3 of 4: gifts. Mirrors
-- lib/db/tables/gifts.dart. One row = either a past gift to a child
-- (occasion / from_who set, is_wish=false) or a wish on a child's
-- wishlist (is_wish=true). Same table on both sides for simplicity.
--
-- RLS — gifts to / wishes for a child are sensitive (surprises,
-- private wishlists), so visibility mirrors child_accounts:
--   SELECT — parent (family-wide) OR kid where member_id = self
--   UPDATE / INSERT / DELETE — parent only (kids can browse but not
--                              tweak their own wishlist via the UI
--                              today; loosen later if the wish-add
--                              flow gets a child-facing entry point).

create table familyfocal.gifts (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  member_id       uuid not null references familyfocal.profiles(id) on delete cascade,
  title           text not null,
  occasion        text,
  gift_date       timestamptz,
  from_who        text,
  is_wish         boolean not null default false,
  is_fulfilled    boolean not null default false,
  notes           text,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index gifts_family_id_idx on familyfocal.gifts (family_id);
create index gifts_member_id_idx on familyfocal.gifts (member_id);

create trigger gifts_set_updated_at
  before update on familyfocal.gifts
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.gifts enable row level security;

create policy gifts_select_self_or_parent
  on familyfocal.gifts
  for select
  to authenticated
  using (
    member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy gifts_insert_parent
  on familyfocal.gifts
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy gifts_update_parent
  on familyfocal.gifts
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

create policy gifts_delete_parent
  on familyfocal.gifts
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename = 'gifts'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.gifts';
  end if;
end $$;
