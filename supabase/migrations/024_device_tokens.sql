-- 024_device_tokens.sql
--
-- Phase 7 (push). Stores the FCM registration tokens of each signed-in
-- device so the server can route a "new task assigned" push to the right
-- person: tasks.assignee_profile_id → profiles.user_id → device_tokens.token.
--
-- A token belongs to one auth user (the person logged in on that device). A
-- user may have several devices, so user_id is NOT unique; the token itself
-- is (the same FCM token is never valid for two users). family_id rides along
-- for RLS scoping and cascade cleanup, consistent with the rest of the schema.
--
-- RLS: a user manages only their own tokens. The push path
-- (notify-task-assigned / send-notification) runs as service_role and reads
-- other members' tokens with RLS bypassed — that's intentional and the only
-- way one member's action can notify another.
--
-- Not added to the realtime publication: device tokens never need to stream
-- to clients.

create table familyfocal.device_tokens (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references familyfocal.families(id) on delete cascade,
  profile_id   uuid not null references familyfocal.profiles(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  token        text not null,
  platform     text not null check (platform in ('ios', 'android')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

-- The same FCM token must map to exactly one row; the app upserts on it
-- (on conflict: refresh user_id/profile_id/last_seen_at when a device is
-- handed to a different login).
create unique index device_tokens_token_unique on familyfocal.device_tokens (token);
create index device_tokens_user_id_idx   on familyfocal.device_tokens (user_id);
create index device_tokens_profile_id_idx on familyfocal.device_tokens (profile_id);
create index device_tokens_family_id_idx  on familyfocal.device_tokens (family_id);

create trigger device_tokens_set_updated_at
  before update on familyfocal.device_tokens
  for each row execute function familyfocal.set_updated_at();

alter table familyfocal.device_tokens enable row level security;

-- A user sees and manages only their own device tokens. family_id is required
-- to match the caller's family too, so a token can't be parked under someone
-- else's family.
create policy device_tokens_select_own
  on familyfocal.device_tokens
  for select
  to authenticated
  using (user_id = auth.uid());

create policy device_tokens_insert_own
  on familyfocal.device_tokens
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and family_id = familyfocal.auth_family_id()
  );

create policy device_tokens_update_own
  on familyfocal.device_tokens
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and family_id = familyfocal.auth_family_id()
  );

create policy device_tokens_delete_own
  on familyfocal.device_tokens
  for delete
  to authenticated
  using (user_id = auth.uid());
