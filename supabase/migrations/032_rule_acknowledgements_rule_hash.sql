-- 032_rule_acknowledgements_rule_hash.sql
--
-- Rule-acknowledgement staleness is now decided by content hashing instead of
-- ordering timestamps. Previously an ack was "current" iff
-- acknowledged_at >= rules.updated_at, but rules.updated_at is re-derived
-- per-device on the client (the rules table ships no updated_at to the app),
-- so clock skew and sync round-trips repeatedly flipped confirmed rules to
-- "outdated" without the parent changing anything.
--
-- The client now stores, on each acknowledgement, a hash of the rule content
-- it confirmed (title + description + target_member_ids, normalised). An ack
-- is current iff that hash still equals the rule's current hash. This column
-- carries that fingerprint between devices.
--
-- Mirrors lib/db/tables/rule_acknowledgements.dart (ruleHash) and
-- lib/features/rules/rule_hash.dart (canonicalisation).

alter table familyfocal.rule_acknowledgements
  add column if not exists rule_hash text;
