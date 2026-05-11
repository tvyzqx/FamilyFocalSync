-- 005_profiles_email_target.sql
--
-- Stores a pre-assigned email for profiles that the parent intends to
-- hand off to a person with their own email account (typically a
-- partner / co-parent). When a join token is later generated for that
-- profile, the email gets copied onto the token; join-family then
-- creates a real auth user with that email and the receiver-chosen
-- password instead of the anonymous join-{uuid}@familyfocal.local
-- device account used for kids without an email.
--
-- Nullable so children, godchildren, and guests can leave it blank.

alter table familyfocal.profiles
  add column if not exists email_target text;
