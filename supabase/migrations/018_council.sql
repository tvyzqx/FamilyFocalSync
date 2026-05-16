-- 018_council.sql
--
-- Phase 6 sub-block 3 — entry 4 of 4: council_topic_categories,
-- council_topics, praise_cards. Mirrors
-- lib/db/tables/council_topic_categories.dart, council_topics.dart,
-- praise_cards.dart.
--
-- Family council is collaborative: any member can add a topic, any
-- member can read the queue, parents drive the moderation actions
-- (delete, change status, attach decision). Praise cards are
-- peer-to-peer notes inside the family — sender owns the row,
-- recipient sees it, parents see all of them for moderation.

-- council_topic_categories -----------------------------------------------

create table familyfocal.council_topic_categories (
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

create index council_topic_categories_family_id_idx
  on familyfocal.council_topic_categories (family_id);

create trigger council_topic_categories_set_updated_at
  before update on familyfocal.council_topic_categories
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.council_topic_categories enable row level security;

create policy council_topic_categories_select_family
  on familyfocal.council_topic_categories
  for select
  to authenticated
  using (family_id = familyfocal.auth_family_id());

create policy council_topic_categories_insert_parent
  on familyfocal.council_topic_categories
  for insert
  to authenticated
  with check (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

create policy council_topic_categories_update_parent
  on familyfocal.council_topic_categories
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

create policy council_topic_categories_delete_parent
  on familyfocal.council_topic_categories
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

-- council_topics ---------------------------------------------------------

create table familyfocal.council_topics (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  added_by_id     uuid not null references familyfocal.profiles(id) on delete cascade,
  topic           text not null,
  scope           text not null default 'family',
  status          text not null default 'open',
  category_id     uuid references familyfocal.council_topic_categories(id) on delete set null,
  priority        integer not null default 5,
  decision        text,
  discussed_at    timestamptz,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index council_topics_family_id_idx on familyfocal.council_topics (family_id);
create index council_topics_added_by_id_idx on familyfocal.council_topics (added_by_id);
create index council_topics_category_id_idx on familyfocal.council_topics (category_id);
create index council_topics_status_idx on familyfocal.council_topics (status);

create trigger council_topics_set_updated_at
  before update on familyfocal.council_topics
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.council_topics enable row level security;

create policy council_topics_select_family
  on familyfocal.council_topics
  for select
  to authenticated
  using (family_id = familyfocal.auth_family_id());

create policy council_topics_insert_family_member
  on familyfocal.council_topics
  for insert
  to authenticated
  with check (
    family_id = familyfocal.auth_family_id()
    and added_by_id = familyfocal.auth_profile_id()
  );

-- Update: the row's author can amend their own topic; parents can
-- amend any topic in the family (status changes, attach decisions).
create policy council_topics_update_self_or_parent
  on familyfocal.council_topics
  for update
  to authenticated
  using (
    added_by_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  )
  with check (
    added_by_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy council_topics_delete_parent
  on familyfocal.council_topics
  for delete
  to authenticated
  using (
    familyfocal.auth_is_parent()
    and family_id = familyfocal.auth_family_id()
  );

-- praise_cards ----------------------------------------------------------
--
-- Sender (from_member_id) writes the row, recipient (to_member_id)
-- reads it. Parents see all of them. UPDATE/DELETE belong to the
-- sender; parent gets DELETE as a moderation backstop.

create table familyfocal.praise_cards (
  id              uuid primary key,
  family_id       uuid not null references familyfocal.families(id) on delete cascade,
  from_member_id  uuid not null references familyfocal.profiles(id) on delete cascade,
  to_member_id    uuid not null references familyfocal.profiles(id) on delete cascade,
  message         text not null,
  emoji           text,
  sent_at         timestamptz not null,
  origin_instance text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false
);

create index praise_cards_family_id_idx on familyfocal.praise_cards (family_id);
create index praise_cards_from_member_id_idx
  on familyfocal.praise_cards (from_member_id);
create index praise_cards_to_member_id_idx
  on familyfocal.praise_cards (to_member_id);

create trigger praise_cards_set_updated_at
  before update on familyfocal.praise_cards
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.praise_cards enable row level security;

create policy praise_cards_select_self_or_parent
  on familyfocal.praise_cards
  for select
  to authenticated
  using (
    from_member_id = familyfocal.auth_profile_id()
    or to_member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy praise_cards_insert_self
  on familyfocal.praise_cards
  for insert
  to authenticated
  with check (
    family_id = familyfocal.auth_family_id()
    and from_member_id = familyfocal.auth_profile_id()
  );

create policy praise_cards_update_sender
  on familyfocal.praise_cards
  for update
  to authenticated
  using (
    from_member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  )
  with check (
    from_member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

create policy praise_cards_delete_sender_or_parent
  on familyfocal.praise_cards
  for delete
  to authenticated
  using (
    from_member_id = familyfocal.auth_profile_id()
    or (
      family_id = familyfocal.auth_family_id()
      and familyfocal.auth_is_parent()
    )
  );

-- Realtime publication. Idempotent.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename = 'council_topic_categories'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.council_topic_categories';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename = 'council_topics'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.council_topics';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'familyfocal'
       and tablename = 'praise_cards'
  ) then
    execute 'alter publication supabase_realtime add table familyfocal.praise_cards';
  end if;
end $$;
