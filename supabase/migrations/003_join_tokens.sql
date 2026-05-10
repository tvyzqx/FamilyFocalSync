-- 003_join_tokens.sql
--
-- Single-use invitation tokens. Replaces the original 010_join_tokens.sql
-- from the initial skeleton, which referenced public.families /
-- public.profiles (both nonexistent) and was never applied to a real DB.
--
-- This rewrite lives in the familyfocal schema (ADR-8) and includes the
-- delivery_channel + email_target columns from the start. The old
-- migration has been deleted as part of P1.3.

create table familyfocal.join_tokens (
  token                   text primary key,
  family_id               uuid not null references familyfocal.families(id) on delete cascade,
  invited_role            text not null check (invited_role in ('parent', 'child')),
  preassigned_profile_id  uuid references familyfocal.profiles(id) on delete set null,
  issued_by               uuid not null references auth.users(id) on delete cascade,
  issued_at               timestamptz not null default now(),
  expires_at              timestamptz not null,
  consumed_at             timestamptz,
  consumed_by             uuid references auth.users(id) on delete set null,

  -- ADR-3 / ADR-2: differentiates QR (10 min, in-person) from email
  -- magic-link (7 days, asynchronous). The TTL itself is enforced in the
  -- edge functions; the column lets us audit which channel a token went
  -- through.
  delivery_channel        text not null default 'qr'
                                check (delivery_channel in ('qr', 'email')),
  email_target            text
);

create index join_tokens_family_id_idx
  on familyfocal.join_tokens (family_id);

create index join_tokens_expires_at_idx
  on familyfocal.join_tokens (expires_at);

-- ADR-4 token hygiene: the generate-join-token edge function looks up open
-- tokens for a profile to close them before issuing a new one. Partial
-- index keeps that lookup cheap as the table grows with consumed rows.
create index join_tokens_open_by_profile_idx
  on familyfocal.join_tokens (preassigned_profile_id)
  where consumed_at is null;

-- RLS: parents see and create their own tokens; nobody else reads them.
-- update + delete stay service-role-only (token consumption happens in
-- the join-family / claim-profile edge functions).

alter table familyfocal.join_tokens enable row level security;

create policy join_tokens_select_issuer
  on familyfocal.join_tokens
  for select
  to authenticated
  using (issued_by = auth.uid());

create policy join_tokens_insert_issuer
  on familyfocal.join_tokens
  for insert
  to authenticated
  with check (issued_by = auth.uid());
