# FamilyFocalSync

Self-hosted sync server for the **FamilyFocal** family-organisation app.

FamilyFocal works fully offline by default. If you want to share family data — profiles, tasks, allowance, rules, family-council topics — between multiple devices and family members, you need a sync server. This repository will eventually contain everything you need to run that server on your own infrastructure: a Supabase-based backend with database schema, row-level-security policies, and edge functions that FamilyFocal expects.

> FamilyFocal does **not** ship a hosted sync service. You run your own. This is intentional — your family's data stays on your server.

---

## Status

**Phases 1, 2 and 6 are shipped** — account bootstrap, QR onboarding, and the full entity schema (tasks, allowance, rules, council, gifts, mood, …) with RLS and realtime are in place. Magic-link onboarding (Phase 5) and push delivery (Phase 7) are still upcoming.

What is in this repository today:

- **Migrations** (`supabase/migrations/`, 001–023) — everything in the `familyfocal` schema:
  - `001`–`004` — `families`, `profiles`, `join_tokens`, RLS helpers (`familyfocal.auth_family_id`, `familyfocal.auth_is_parent`) + policies, and the `supabase_realtime` publication.
  - `005`–`021` — entity tables with their RLS and realtime: `task_categories`, `tasks`, `child_accounts`, `development_entries`, `child_preferences`, `savings_goals`, `child_goals`, `allowance_entries`, `rules`/`rule_categories`/`rule_acknowledgements`, `gifts`, council (`council_topics`/`council_topic_categories`/`praise_cards`), `mood_entries`.
  - `022_tasks_recurrence.sql` — `recurrence_interval` + `recurrence_mode` columns on `tasks`.
  - `023_meta.sql` — `familyfocal.meta(schema_version)`, an auth-free app↔server compatibility handshake.
- **Five edge functions** (`supabase/functions/`):
  - `bootstrap-family` — first parent + family signup (anonymous, ships the confirmation email).
  - `generate-join-token` — parent generates a one-time QR token for a profile.
  - `join-family` — receiver redeems a token and is wired up as that profile.
  - `check-join-status` — parent polls whether the token has been claimed.
  - `revoke-user-sessions` — parent revokes all sessions of a target profile.
- **Contract guardrails** (`scripts/`) — an additive-only migration guard (`check_migrations.py`, wired into CI + a pre-commit hook) and a cross-tenant RLS test suite (`run_rls_tests.sh`) that keep published-app compatibility and family isolation enforced. See `docs/cloud-vs-selfhost.md`.

What is **not** here yet (planned, see [Roadmap](#roadmap)):

- Magic-link onboarding edge functions (`invite-by-email`, `claim-profile`).
- Push delivery: a `device_tokens` migration + a `send-notification` edge function.

Account creation now works directly from the app via `bootstrap-family` — manual family/account setup in the Supabase dashboard is no longer required.

---

## Roadmap

The full implementation plan lives in the FamilyFocal app repository at `docs/sync-implementation-plan.md`. High-level milestones:

| Phase | Status     | Adds                                                                          |
|-------|------------|-------------------------------------------------------------------------------|
| 1     | shipped    | Migrations 001–004 (`families`, `profiles`, `join_tokens`, realtime publication) + RLS |
| 2     | shipped    | Edge function `bootstrap-family` (parent email-signup) + `revoke-user-sessions` |
| 5     | upcoming   | Edge functions `invite-by-email` + `claim-profile`; magic-link onboarding     |
| 6     | shipped    | Migrations 005–022: `tasks` (+ recurrence), `allowance`, `rules`, `council`, `gifts`, `praise`, `mood`, … with RLS + realtime |
| 7     | upcoming   | `device_tokens` migration + edge function `send-notification`                 |

Outside the phase plan, migration `023_meta.sql` adds a schema-version handshake and `scripts/` adds an additive-only migration guard + cross-tenant RLS tests (see `docs/cloud-vs-selfhost.md`).

This README is updated each time a phase lands.

---

## Requirements

- A Linux server (any modern distribution) with at least 2 GB RAM and 20 GB disk
- A domain name pointing to that server (e.g. `sync.example.com`)
- Docker + Docker Compose
- An SMTP account for sending account/invitation emails (e.g. Postmark, Brevo, Mailgun, Amazon SES — anything that speaks SMTP). Required from Phase 5 (magic-link onboarding) onwards.
- Basic command-line skills

If you also want to administer the database from your laptop:
- The [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) (optional, makes migrations and function deploys easier)

---

## Setup

The setup follows the [official Supabase self-hosting guide](https://supabase.com/docs/guides/self-hosting/docker) and adds the FamilyFocal-specific schema on top.

### 1. Install Supabase via Docker Compose

```bash
git clone --depth 1 https://github.com/supabase/supabase
cd supabase/docker
cp .env.example .env
```

Edit `.env` and set at least:

| Variable | Notes |
|---|---|
| `POSTGRES_PASSWORD` | Strong random password |
| `JWT_SECRET` | At least 32 random characters |
| `ANON_KEY` | Generate from `JWT_SECRET` — see Supabase docs |
| `SERVICE_ROLE_KEY` | Generate from `JWT_SECRET` — see Supabase docs |
| `SITE_URL` | Public URL of your sync server, e.g. `https://sync.example.com` |
| `API_EXTERNAL_URL` | Same as `SITE_URL` |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_SENDER_NAME`, `SMTP_ADMIN_EMAIL` | Your SMTP provider (only required from Phase 5) |
| `ENABLE_EMAIL_SIGNUP` | `true` |
| `ENABLE_EMAIL_AUTOCONFIRM` | `false` (users must confirm their email) |

A starter file `.env.example` in this repository documents the FamilyFocal-specific variables (TTLs, etc.).

Put a reverse proxy (Caddy, nginx, Traefik) in front so that `https://sync.example.com` reaches the Supabase Kong gateway on port `8000`.

Start the stack:

```bash
docker compose up -d
```

Verify it's healthy:

```bash
docker compose ps
curl https://sync.example.com/auth/v1/health
```

### 2. Schema convention

> **The schema name `familyfocal` is hardcoded in the FamilyFocal app's Supabase client and is not configurable.** The migrations in this repository create everything in `familyfocal`, and the app sends `Accept-Profile: familyfocal` on every PostgREST request. Don't rename it. This intentionally keeps FamilyFocal isolated from any other apps that share the same Supabase instance.

If you run a single-purpose Supabase instance for FamilyFocal, the steps below are still required (they bootstrap the schema you'll be applying migrations into). If you share the instance with other apps, **all three steps are additive** — they don't touch your other apps' configuration.

**a) Create the schema and grant role privileges (once):**

```sql
create schema if not exists familyfocal;

grant usage on schema familyfocal to anon, authenticated, service_role;

alter default privileges in schema familyfocal
  grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema familyfocal
  grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema familyfocal
  grant all on functions to anon, authenticated, service_role;
```

**b) Add `familyfocal` to PostgREST's exposed schemas.** Edit `supabase/docker/.env`:

```
PGRST_DB_SCHEMAS=public,storage,graphql_public,familyfocal
```

If you already have other apps in this list, prepend or append `familyfocal` — don't replace the existing entries. Then restart the stack: `docker compose up -d`.

**b.2) Forward the public URL into the edge functions container.** The `generate-join-token` function returns a `server` URL inside the QR payload that the second device uses to sign in. On managed Supabase the in-container `SUPABASE_URL` is already the public URL, but on self-hosted installs it points at `http://kong:8000` and is unreachable from outside the docker network.

Set `SUPABASE_PUBLIC_URL` on the edge-functions container in `supabase/docker/.env`:

```
SUPABASE_PUBLIC_URL=https://sync.example.com
```

Then make sure the value is forwarded into the `functions` service in `docker-compose.yml` (most self-hosted layouts already pass through the environment file; if yours doesn't, add `SUPABASE_PUBLIC_URL: ${SUPABASE_PUBLIC_URL}` to that service's `environment:` block) and recreate the container:

```bash
docker compose up -d functions
```

The function falls back to `SUPABASE_URL` if `SUPABASE_PUBLIC_URL` isn't set — handy for local dev — but for any deployment that issues QR codes consumed off-host, this variable is required.

**c) Add the FamilyFocal deep-link URLs to Auth.** In the Supabase dashboard under **Auth → URL Configuration → Additional redirect URLs**, add:

- `familyfocal://join`
- `familyfocal://claim`

Both entries are also pre-populated in `supabase/config.toml` of this repository for completeness, but on self-hosted installs the dashboard / API value is the source of truth.

### 3. Apply the FamilyFocal migrations

The FamilyFocal migrations live in `supabase/migrations/` of **this** repository. Apply them in order:

**Option A — with the Supabase CLI** (recommended):

```bash
# from the root of this repository
supabase link --project-ref <your-project-ref>
supabase db push
```

**Option B — directly with `psql`**:

```bash
for f in supabase/migrations/*.sql; do
  psql "postgresql://postgres:${POSTGRES_PASSWORD}@localhost:5432/postgres" -f "$f"
done
```

Verify the migrations landed:

```bash
psql "$DB_URL" -c "\dt familyfocal.*"
```

After Phase 1 you should see `families`, `profiles`, and `join_tokens`. Later phases add the entity tables (`tasks`, `allowance`, …) and `device_tokens` to the same schema.

### 4. Deploy the edge functions

Currently shipping:

```bash
supabase functions deploy generate-join-token
supabase functions deploy join-family
supabase functions deploy check-join-status
```

Set the FamilyFocal-specific secrets:

```bash
# QR-onboarding token TTL (in minutes; 10 is recommended for in-person scans).
supabase secrets set JOIN_TOKEN_TTL_MINUTES=10

# Magic-link / email-invite token TTL (in minutes; 10080 = 7 days).
# Only used once Phase 5 (invite-by-email) is deployed.
supabase secrets set INVITE_TTL_MINUTES=10080
```

`bootstrap-family`, `invite-by-email`, `claim-profile`, and `send-notification` are not in this repository yet — they ship with their respective phases.

### 5. Configure auth (email + templates)

In the Supabase dashboard (or via `supabase` CLI):

- **Auth → Providers → Email**: enabled, with confirmation.
- **Auth → URL Configuration**: Site URL set to your sync server, e.g. `https://sync.example.com`. Redirect URLs were added in step 2c.
- **Auth → Email templates**: customize the confirmation/recovery emails if you want. SMTP credentials are required from Phase 5 onwards (magic-link onboarding).

Test by signing up with your own email — you should receive a confirmation message.

### 6. Connect the app

Open the FamilyFocal app on your phone:

1. Go to **Settings → Data & Sync → Sync server**
2. Enter:
   - **Server URL**: `https://sync.example.com`
   - **Anon key**: the `ANON_KEY` from your `.env`
3. Tap **Test connection** — should report success.
4. Tap **Save**, then restart the app.

Account creation and family-bootstrap from the app are added in Phase 2 — until then the server only accepts connections from clients that already have a session (e.g. created manually via the Supabase dashboard for testing).

---

## Updating

When FamilyFocal ships new schema migrations, this repository is updated. To apply:

```bash
git pull
supabase db push   # or re-run new files via psql
supabase functions deploy <changed-functions>
```

The app handles backward-compatible schema changes automatically; check release notes for breaking changes.

---

## Troubleshooting

**App shows "no connection"**
Verify `https://<your-server>/auth/v1/health` returns `200` from outside your server. Check that the reverse-proxy SSL certificate is valid.

**Sign-up email never arrives**
Check Supabase Auth logs (`docker compose logs auth`). Most common cause is incorrect SMTP credentials. Test SMTP independently with `swaks` or similar.

**Family data doesn't sync between devices**
Both devices must be signed in with the same family account. Guest profiles created locally on a device only sync after they've been claimed by an account.

**Realtime doesn't update other devices live**
Verify `realtime` is enabled in `config.toml` and the `supabase-realtime` container is running. Polling fallback (every 20 s) should still work even without realtime.

---

## Project structure

```
supabase/
├── config.toml             # Supabase project config (ports, auth redirects, functions)
├── migrations/             # Database schema, RLS, indexes — apply in order
│   ├── 001_initial_schema.sql        # families, profiles
│   ├── 002_rls_policies.sql          # RLS helpers + family-scoped policies
│   ├── 003_join_tokens.sql
│   ├── 004_realtime_publication.sql
│   ├── …                             # 005–021: entity tables (task_categories,
│   │                                 #   tasks, child_accounts, allowance, rules,
│   │                                 #   gifts, council, mood, …) + RLS + realtime
│   ├── 022_tasks_recurrence.sql      # recurrence_interval + recurrence_mode on tasks
│   └── 023_meta.sql                  # schema_version handshake (familyfocal.meta)
└── functions/              # Edge functions (Deno/TypeScript)
    ├── bootstrap-family/        # first parent + family signup (anonymous)
    ├── generate-join-token/     # parent issues a one-time QR token
    ├── join-family/             # receiver redeems a token
    ├── check-join-status/       # parent polls token redemption
    └── revoke-user-sessions/    # parent revokes a profile's sessions

scripts/                    # additive-only migration guard, RLS tests, git hooks
docs/                       # cloud-vs-self-host architecture + gap plan
```

All database objects live in the `familyfocal` schema (see [Schema convention](#2-schema-convention)).

---

## License

See `LICENSE`. The FamilyFocal app itself lives at https://github.com/tvyzqx/familyfocal.
