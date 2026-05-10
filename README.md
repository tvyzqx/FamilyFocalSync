# FamilyFocalSync

Self-hosted sync server for the **FamilyFocal** family-organisation app.

FamilyFocal works fully offline by default. If you want to share family data — profiles, tasks, allowance, rules, family-council topics — between multiple devices and family members, you need a sync server. This repository will eventually contain everything you need to run that server on your own infrastructure: a Supabase-based backend with database schema, row-level-security policies, and edge functions that FamilyFocal expects.

> FamilyFocal does **not** ship a hosted sync service. You run your own. This is intentional — your family's data stays on your server.

---

## Status

**Skeleton — schema and functions are added incrementally as sync support lands feature by feature** (profiles first, then tasks, allowance, rules, council, gifts, push notifications).

What is in this repository today:

- One migration: `supabase/migrations/010_join_tokens.sql` (join-token table for QR onboarding).
- Three edge functions:
  - `generate-join-token` — parent generates a one-time token for a profile.
  - `join-family` — receiver redeems a token and is wired up as that profile.
  - `check-join-status` — parent polls whether the token has been claimed.

What is **not** here yet (planned, see [Roadmap](#roadmap)):

- Migrations for `families`, `profiles`, and the rest of the family data model.
- Row-level-security policies.
- Edge functions for parent bootstrap (`bootstrap-family`), magic-link onboarding (`invite-by-email`, `claim-profile`), guest upgrade, and push delivery (`send-notification`).

The app-side configuration UI ships with FamilyFocal today, but until at least the Phase 1 migrations and `bootstrap-family` are added, the only feature exercising this server is the QR-onboarding flow against a profile that already exists in the database.

---

## Roadmap

The full implementation plan lives in the FamilyFocal app repository at `docs/sync-implementation-plan.md`. High-level milestones:

| Phase | Adds                                                                            |
|-------|---------------------------------------------------------------------------------|
| 1     | Migrations `001_initial_schema.sql` (`families`, `profiles`) + `002_rls_policies.sql` + `011_join_tokens_email.sql` |
| 2     | Edge function `bootstrap-family` (parent email-signup)                          |
| 5     | Edge functions `invite-by-email` + `claim-profile`; magic-link onboarding       |
| 6     | Migrations and RLS for `tasks`, `allowance`, `rules`, `council`, `gifts`, `praise` |
| 7     | Migration `009_device_tokens.sql` + edge function `send-notification`           |

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

### 2. Apply the FamilyFocal migrations

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
psql "$DB_URL" -c "\dt public.*"
```

Today this only creates `join_tokens`. As phases land, more tables (`families`, `profiles`, `tasks`, …) will be added — see [Roadmap](#roadmap).

### 3. Deploy the edge functions

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

`bootstrap-family`, `invite-by-email`, `claim-profile`, `upgrade-guest-account`, and `send-notification` are not in this repository yet — they ship with their respective phases.

### 4. Configure auth

In the Supabase dashboard (or via `supabase` CLI):

- **Auth → Providers → Email**: enabled, with confirmation
- **Auth → URL Configuration**:
  - Site URL: `https://sync.example.com`
  - Additional redirect URLs:
    - `familyfocal://join`
    - `familyfocal://claim`

  These two custom-scheme entries are required so Supabase accepts magic-link redirects back into the app. They are pre-populated in `supabase/config.toml`.
- **Auth → Email templates**: customize the confirmation/recovery emails if you want

Test by signing up with your own email — you should receive a confirmation message.

### 5. Connect the app

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
│   └── 010_join_tokens.sql
└── functions/              # Edge functions (Deno/TypeScript)
    ├── generate-join-token/
    ├── join-family/
    └── check-join-status/
```

---

## License

See `LICENSE`. The FamilyFocal app itself lives at https://github.com/tvyzqx/familyfocal.
