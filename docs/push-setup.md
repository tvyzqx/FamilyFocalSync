# Push notifications — setup

Phase 7. Server side of the push design (see `docs/cloud-vs-selfhost.md` →
Push-Architektur for the why).

> **Status (2026-05-31):** the cloud relay is **live on `api.7-tm.de`**.
> Migration 024 applied; `send-notification` + `notify-task-assigned` deployed;
> the `tasks` INSERT trigger (`familyfocal.tg_notify_task_assigned`) is installed;
> the full chain (trigger → notify → relay → FCM → dead-token prune) was verified
> end-to-end against real FCM. Secrets live in `/opt/supabase/.env` (not in git);
> `FCM_SERVICE_ACCOUNT` is stored base64-encoded. **The Firebase key used at
> deploy was exposed in chat and must be rotated** — replace `FCM_SERVICE_ACCOUNT`
> (base64 of the new JSON) in `.env` and `docker compose up -d functions`.
> Still open: iOS APNs auth key in Firebase (no iOS delivery without it), and the
> app side (token registration + handlers + local reminders).

```
parent creates assigned task
        │ INSERT familyfocal.tasks
        ▼
  Database Webhook ──Bearer PUSH_WEBHOOK_SECRET──▶ notify-task-assigned
                                                        │ looks up assignee
                                                        │ → profiles.user_id
                                                        │ → device_tokens
                                                        ▼
                              POST PUSH_SENDER_URL ─Bearer PUSH_RELAY_KEY─▶ send-notification
                                                                                │ holds FCM_SERVICE_ACCOUNT
                                                                                ▼
                                                                          FCM ─▶ device
```

Time-based reminders ("due tomorrow", recurring instances) are **not** here —
they are local notifications scheduled on the device (app side).

## Pieces

| Piece | Where it runs | Holds FCM creds? |
|---|---|---|
| `024_device_tokens.sql` | every DB | — |
| `notify-task-assigned` (function) | cloud **and** self-host | no |
| `send-notification` (function) | relay host only (you / cloud) | **yes** |
| Database Webhook on `tasks` INSERT | cloud **and** self-host | — |

`send-notification` is the only component with FCM credentials. Self-host
servers cannot send to FCM directly (the device tokens belong to the Firebase
project in the published app), so their `notify-task-assigned` points
`PUSH_SENDER_URL` at the publisher's hosted relay.

## Secrets

`send-notification` (relay host / cloud only):
- `FCM_SERVICE_ACCOUNT` — the full Firebase service-account JSON (one line).
- `PUSH_RELAY_KEY` — shared secret callers must present.

`notify-task-assigned` (every server):
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` — to read profiles/device_tokens.
- `PUSH_WEBHOOK_SECRET` — secret the DB webhook presents to this function.
- `PUSH_SENDER_URL` — relay host (cloud) calling its own relay: use the internal
  gateway `http://kong:8000/functions/v1/send-notification` (no public hairpin);
  self-host: the publisher's public hosted relay URL.
- `PUSH_RELAY_KEY` — must match the relay's key.
- `PUSH_INCLUDE_CONTENT` — `true` only on the cloud (first-party data); leave
  unset on self-host so the push body stays generic (no names/titles over the
  relay; the app fetches details from its own server on open).

```bash
supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
supabase secrets set PUSH_RELAY_KEY=… PUSH_WEBHOOK_SECRET=… PUSH_SENDER_URL=… PUSH_INCLUDE_CONTENT=true
```

## Deploy

Relay host / cloud:
```bash
supabase functions deploy send-notification
supabase functions deploy notify-task-assigned
```
Self-host: deploy only `notify-task-assigned` (its `send-notification` would be
unused). On this server's docker layout, copy into the edge-runtime volume the
same way as the other functions (see SERVER_NOTES.md).

## Database Webhook (every server)

Create it via the Supabase dashboard (Database → Webhooks): table
`familyfocal.tasks`, event INSERT, type "Supabase Edge Functions" →
`notify-task-assigned`, with HTTP header
`Authorization: Bearer <PUSH_WEBHOOK_SECRET>`.

Portable alternative (pg_net trigger — fill in your URL/secret; NOT a tracked
migration because both are per-environment):

```sql
-- requires the pg_net extension
create or replace function familyfocal.tg_notify_task_assigned()
returns trigger language plpgsql security definer
set search_path = familyfocal, net, pg_temp as $$
begin
  perform net.http_post(
    url     := '<PUSH base>/functions/v1/notify-task-assigned',
    headers := jsonb_build_object(
                 'Authorization', 'Bearer <PUSH_WEBHOOK_SECRET>',
                 'Content-Type',  'application/json'),
    body    := jsonb_build_object('type','INSERT','table','tasks',
                 'schema','familyfocal','record', to_jsonb(new))
  );
  return new;
end $$;

create trigger tasks_notify_assigned
  after insert on familyfocal.tasks
  for each row
  when (new.assignee_profile_id is not null and coalesce(new.is_template,false) = false)
  execute function familyfocal.tg_notify_task_assigned();
```

The `when (...)` clause keeps the webhook from firing for unassigned tasks and
templates.

## App side (separate Flutter repo)

Out of scope for this repo; tracked as a Mac-Claude prompt:
- register/refresh the FCM token → upsert into `familyfocal.device_tokens`
  (`user_id` = `auth.uid()`, `profile_id` = own profile, `family_id` = own family);
- on the `task_assigned` data push, route into the app / refresh from the server;
- schedule **local** notifications for due-date and recurring reminders (Fall A);
- Firebase/APNs setup if not already present.

## Follow-ups (not built yet)
- Relay auth: issue/rotate `PUSH_RELAY_KEY` per self-host instance + rate-limit
  the relay (abuse surface; it's verify_jwt = false).
- Gate the cloud relay behind `REQUIRE_ENTITLEMENT`.
- Reassignment pushes (UPDATE of assignee_profile_id), not just INSERT.
