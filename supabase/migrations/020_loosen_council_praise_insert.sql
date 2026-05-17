-- 020_loosen_council_praise_insert.sql
--
-- Phase 6 follow-up: loosen the INSERT row-level-security check on
-- council_topics and praise_cards so parents can post on behalf of
-- any family member.
--
-- Why: only parent profiles can sign in (bootstrap_service.dart
-- rejects child role at login). The local active-member picker lets
-- a parent device act *as* a child without re-authenticating, so
-- when a topic / praise card is created with "active member = kid",
-- the payload carries added_by_id / from_member_id = kid.profile_id
-- while auth_profile_id() resolves to the parent's profile. The old
-- strict equality check rejected those inserts with 42501.
--
-- The new check follows the same "self OR parent in same family"
-- pattern already used by mood_entries (019) and rule_acknowledgements
-- (016). Children with their own login still can only post as
-- themselves — auth_is_parent() will be false for them.

drop policy if exists council_topics_insert_family_member
  on familyfocal.council_topics;

create policy council_topics_insert_family_member
  on familyfocal.council_topics
  for insert
  to authenticated
  with check (
    family_id = familyfocal.auth_family_id()
    and (
      added_by_id = familyfocal.auth_profile_id()
      or familyfocal.auth_is_parent()
    )
  );

drop policy if exists praise_cards_insert_self
  on familyfocal.praise_cards;

create policy praise_cards_insert_self
  on familyfocal.praise_cards
  for insert
  to authenticated
  with check (
    family_id = familyfocal.auth_family_id()
    and (
      from_member_id = familyfocal.auth_profile_id()
      or familyfocal.auth_is_parent()
    )
  );
