-- 028_council_child_scope.sql
--
-- Adds a third council scope: 'child' — one-on-one topics between the
-- parents and a single child ("Kind & Eltern"). Mirrors the existing
-- 'family' (everyone) and 'parents' (parents only) scopes on
-- familyfocal.council_topics.
--
-- A child-scope topic is pinned to exactly one child via the new
-- child_id column (a profiles.id, like added_by_id). The goal is to
-- prepare individual topics and make transparent what was discussed
-- with that specific child.
--
-- Visibility:
--   * Parents see every topic in the family (all three scopes), and
--     filter the child-scope queue by child in the client.
--   * A child sees the shared 'family' council plus only the 'child'
--     topics pinned to themselves. They must NOT see 'parents' topics
--     nor another sibling's 'child' topics.
--
-- The previous select policy (council_topics_select_family) granted
-- every family member read access to every row regardless of scope.
-- Now that children sign in with their own profile (role-agnostic
-- child sync, device lock), that was too broad — a child could pull
-- the parents-only queue. This migration replaces it with a
-- scope-aware policy.

-- child_id ----------------------------------------------------------------

alter table familyfocal.council_topics
  add column if not exists child_id uuid
    references familyfocal.profiles(id) on delete cascade;

create index if not exists council_topics_child_id_idx
  on familyfocal.council_topics (child_id);

-- A child-scope topic must name the child it belongs to; the other
-- scopes never carry a child_id.
alter table familyfocal.council_topics
  drop constraint if exists council_topics_child_scope_has_child;
alter table familyfocal.council_topics
  add constraint council_topics_child_scope_has_child
  check (scope <> 'child' or child_id is not null);

-- SELECT: scope-aware -----------------------------------------------------

drop policy if exists council_topics_select_family
  on familyfocal.council_topics;

create policy council_topics_select_scoped
  on familyfocal.council_topics
  for select
  to authenticated
  using (
    family_id = familyfocal.auth_family_id()
    and (
      familyfocal.auth_is_parent()
      or scope = 'family'
      or (scope = 'child' and child_id = familyfocal.auth_profile_id())
    )
  );

-- INSERT: keep parent-on-behalf-of, but stop a child posting outside
-- their lane ----------------------------------------------------------------
--
-- Parents may post any scope for anyone (auth_is_parent()). A child
-- with their own login may only post 'family' topics or 'child' topics
-- pinned to themselves — never a 'parents' topic, never a sibling's
-- 'child' topic.

drop policy if exists council_topics_insert_family_member
  on familyfocal.council_topics;

create policy council_topics_insert_family_member
  on familyfocal.council_topics
  for insert
  to authenticated
  with check (
    family_id = familyfocal.auth_family_id()
    and (
      familyfocal.auth_is_parent()
      or (
        added_by_id = familyfocal.auth_profile_id()
        and scope <> 'parents'
        and (scope <> 'child' or child_id = familyfocal.auth_profile_id())
      )
    )
  );

-- UPDATE keeps the existing self-or-parent policy (018). A child can
-- still amend their own topic but, being non-parent, the insert/select
-- rules above already box them into their own lane; the with-check on
-- update mirrors 018 and is left untouched.
