# Cloud-Sync vs. Self-Host — Architektur & offene Arbeit

Ziel: **ein** Codebase / **ein** Schema bedient zwei Betriebsmodi.

- **Cloud-Sync** — deine zentrale Instanz, Zugang über In-App-Abo (Apple & Google
  als getrennte Store-Produkte).
- **Self-Host** — der User betreibt seinen eigenen Server, **ohne** Abo, mit vollem
  Funktionsumfang.

Beides muss aus demselben Repo deploybar sein. Kein Fork, kein Cloud-Branch.

## Launch-Strategie (entschieden 2026-05-31)

**v1 = Self-Host only. Cloud + Abo kommen als v2** (additiv, ohne installierte
v1-Apps zu brechen).

Maßstab für "erste Version funktioniert auch später" = **Vertrags-Stabilität**, nicht
Feature-Vollständigkeit. Eine veröffentlichte App ruft für immer den damaligen
Vertrag (Schema + Edge-Function-APIs + eingebrannte Konstanten) auf.

Was JETZT (vor Release) zu tun ist — nur die Leitplanken:
1. ✅ **CI-/Pre-Commit-Guard "additive only"** — gebaut, s. u.
2. ✅ **RLS-Cross-Tenant-Testsuite** — gebaut (`supabase/tests/rls_cross_tenant.sql`,
   `scripts/run_rls_tests.sh`), gegen echtes Schema verifiziert (rollback-gekapselt).
   Offen: in CI verdrahten (braucht `supabase/postgres`-Image als Service mit
   auth-Schema + Rollen; aktuell manuell/serverseitig ausführbar).
3. ✅ **Schema-Versions-Handshake**: `familyfocal.meta(schema_version)` (Migration
   `023_meta.sql`, advertises contract version 22 = `022_tasks_recurrence`) → App
   liest auth-frei via PostgREST und warnt bei veraltetem Self-Host-Server. Version
   monoton bumpen, wenn eine Migration den App-Daten-Vertrag erweitert (Infra-
   Migrationen wie meta selbst zählen nicht). Noch zu deployen (Server-Workflow).

Alles andere (Entitlement, IAP, Abuse, delete-account, Push, Magic-Link,
E-Mail-Templates) ist serverseitig-additiv und kommt in/nach v2.

Forward-Compat-Regeln ab v1: nur **nullable Spalten mit Default** hinzufügen, nie
Spalten/Tabellen entfernen oder umbenennen, die eine veröffentlichte App nutzt.
Falls v2 die Cloud-URL/Anon-Key in die App brennt → **stabile Config-URL** statt
Key direkt einbrennen (Rotation ohne App-Update möglich).

## Grundprinzip: der Code ist bereits mandantenfähig

RLS skopiert alles nach `family_id` (`auth_family_id()` / `auth_is_parent()` in
`002_rls_policies.sql`, gleiches Muster in jeder Entity-Migration). Viele fremde
Familien können sicher in einer Instanz koexistieren — Voraussetzung für Cloud.

## Modus-Schalter: `REQUIRE_ENTITLEMENT`

| | Cloud | Self-Host |
|---|---|---|
| `REQUIRE_ENTITLEMENT` (Server-Secret) | `true` | `false` (Default) |
| Abo-Gate in RLS | aktiv | inert |
| Anon-Key | fest im App-Code | User trägt eigenen ein |

- Das Flag wirkt **server-seitig** (Secret), nicht im App-Code — sonst per
  modifizierter App umgehbar.
- Self-Host liefert das Secret nie → Gate aus → "ohne Abo" garantiert.

## Login-Wege in der App (zwei)

1. **Cloud-Sync**: Server-URL + Anon-Key fest verschaltet, ein Tap, Zugang per Abo.
2. **Eigener Server**: bestehender Flow (Settings → Sync server), URL + Anon-Key
   selbst eingeben.

### Der Anon-Key ist KEIN Türschloss

Der Anon-Key ist öffentlich (aus dem App-Binary auslesbar). Er routet nur zur
Cloud. Der Zugang wird ausschließlich **server-seitig** über das Entitlement-Gate
erzwungen:

```
Anon-Key  → "du landest auf der Cloud"     (öffentlich)
Login/JWT → "du bist Familie X"            (RLS-Scoping, vorhanden)
Abo-Gate  → "Familie X darf syncen"        (zu bauen)
```

## Abo / Entitlement

- Tabelle `familyfocal.entitlements` (`family_id`, `status`, `expires_at`,
  `source` = `apple|google`, `original_transaction_id`).
- RLS-Helper `auth_has_active_subscription()` analog zu `auth_is_parent()`.
- Gate-Policies hinter `REQUIRE_ENTITLEMENT`.
- **Abgelaufenes Abo sperrt nur Schreiben, nie Lesen/Export** (DSGVO + UX).
- Validierungsweg (RevenueCat vs. direkte Store-APIs) noch offen — schreibt am Ende
  nur in `entitlements`, ändert Schema/Gate nicht. RevenueCat empfohlen (Apple +
  Google in einem Webhook).

## E-Mail-/URL-Bestätigungen hübsch darstellen

Gilt für beide Modi, nur Branding/Domain via `SITE_URL` unterschiedlich.

1. **Gebrandete Templates** unter `supabase/templates/` (Confirmation, Recovery,
   Magic-Link, Invite), in GoTrue gemountet, per `GOTRUE_MAILER_TEMPLATES_*` +
   `GOTRUE_MAILER_SUBJECTS_*` referenziert.
2. **Landing-Page nach Klick**:
   - Handy + App installiert → Deep-Link `familyfocal://join` öffnet App direkt.
   - Fallback (Desktop / App fehlt) → kleine gebrandete HTML-Seite
     (`/confirmed`): "✅ bestätigt" + "App öffnen" + Store-Links. Edge Function
     (HTML) oder statische Datei hinter Reverse-Proxy. Liegt im Repo, damit
     Self-Hoster sie mit-deployen.

## Gap-Liste (priorisiert, vor Release)

### P0 — Sicherheit / Mandantentrennung
- [x] Automatisierte RLS-Cross-Tenant-Testsuite (Familie A sieht/ändert B nicht).
      → `supabase/tests/rls_cross_tenant.sql`, Runner `scripts/run_rls_tests.sh`.
- [ ] Anon-Grants entschärfen (`README.md:122` `grant all ... to anon` → minimal).
- [x] CI-Guard: scheitert bei Tabelle in `familyfocal` ohne aktivierte RLS.
      → `scripts/check_migrations.py` (prüft zugleich additive-only, s. u.).

#### Migration-Guard (gebaut)
`scripts/check_migrations.py` validiert den gesamten Migrationssatz:
- verbietet vertragsbrechende DDL: `DROP TABLE`/`DROP COLUMN`/`RENAME`,
  Spalten-`TYPE`-Wechsel, `SET NOT NULL`, `ADD COLUMN NOT NULL` ohne `DEFAULT`.
- erlaubt additiv/ungefährlich: `DROP POLICY`, `DROP CONSTRAINT` (lockert nur),
  nullable `ADD COLUMN`, `ADD COLUMN NOT NULL DEFAULT …`.
- erzwingt `enable row level security` auf jeder `familyfocal`-Tabelle.
Verdrahtung: GitHub Actions (`.github/workflows/ci.yml`) bei push/PR +
lokaler Pre-Commit-Hook (`scripts/install-hooks.sh` → `scripts/git-hooks/pre-commit`).
Nicht erzwungen (dokumentierte Sorgfaltspflicht): neue verschärfende
Constraints (`ADD CONSTRAINT ... CHECK`, neuer UNIQUE) können Writes alter
Clients ablehnen — bewusst additiv halten.

### P0 — Abo-Layer
- [ ] Migration `entitlements` + `auth_has_active_subscription()`.
- [ ] `REQUIRE_ENTITLEMENT`-gegatete Schreib-Policies (Lesen/Export immer offen).

### P1 — Abuse-Schutz (nur Cloud, inert bei Self-Host)
- [ ] Rate-Limiting vor `bootstrap-family` / `join-family` (verify_jwt=false).
- [ ] CAPTCHA/Turnstile beim Signup.
- [ ] Quotas pro Familie (Profile/Zeilen/Storage).

### P1 — DSGVO (EU, kommerziell)
- [ ] `delete-account` Edge Function (in `002_rls_policies.sql:51` erwähnt, fehlt).
- [ ] Datenexport pro Familie.
- [ ] Datenschutzerklärung, Sub-Prozessoren (SMTP, Store/RevenueCat), Server-Standort.

### P1 — Betrieb
- [ ] Automatisierte Backups + getesteter Restore.
- [ ] Migrations-Tracking (`schema_migrations`-Tabelle / idempotent) statt manueller psql-Schleife.
- [ ] Schema-Versions-Handshake (`familyfocal.meta(schema_version)`) → App warnt bei zu altem Server.
- [ ] Monitoring / Uptime / Alerting.

### P2 — fehlende Features (Roadmap)
- [ ] Phase 5: `invite-by-email` + `claim-profile` (Magic-Link, SMTP).
- [ ] Phase 7: Push — in Arbeit, s. u.

#### Push-Architektur (entschieden 2026-05-31)
Zwei Benachrichtigungs-Arten, technisch getrennt:
- **Fall A — zeitgesteuert** (morgen fällig, neue wiederkehrende Instanz):
  lokale Notifications auf dem Gerät (`flutter_local_notifications.zonedSchedule`),
  beim Sync eingeplant. Feuern auch bei beendeter App. Kein Server, self-host = cloud.
  → reine App-Arbeit.
- **Fall B — neue Zuweisung weckt fremdes Gerät**: echter OS-Push (APNs/FCM).
  Supabase liefert NICHT aus; nur Orchestrierung (DB-Webhook → Edge Function → FCM).
  FCM-Tokens gehören zum Firebase-Projekt im App-Binary ⇒ Self-Host kann nicht direkt
  senden. Lösung: **Relay, das der Betreiber hostet.**
    - `send-notification` (Edge Function, hält FCM-Service-Account): nimmt
      `{messages:[{token, platform, notification, data}]}`, sendet via FCM v1,
      meldet ungültige Tokens zurück. Auth via `PUSH_RELAY_KEY` (self-host) bzw.
      service_role (cloud-intern). = Cloud-Sender UND Self-Host-Relay.
    - `notify-task-assigned` (Edge Function, läuft self-host UND cloud): DB-Webhook
      auf `tasks` INSERT → Assignee → `profiles.user_id` → `device_tokens` → POST an
      `PUSH_SENDER_URL` mit `PUSH_RELAY_KEY`; prunt zurückgemeldete Tote Tokens.
      Cloud: `PUSH_SENDER_URL` = lokal. Self-Host: = gehostetes Relay des Betreibers.
    - iOS bei beendeter App: nur `notification`-Payload zuverlässig (kein silent).
      Self-Host sendet deshalb **generischen** Text (keine Namen/Inhalte) übers Relay;
      App holt Details beim Öffnen vom eigenen Server (Datenschutz).
    - Secrets: `FCM_SERVICE_ACCOUNT` (nur am Relay/Cloud), `PUSH_RELAY_KEY`,
      `PUSH_SENDER_URL`. Tabelle `device_tokens` (Migration 024).
    - Cloud später per `REQUIRE_ENTITLEMENT` gaten; Relay-Aufrufe rate-limiten.
- [ ] Realtime im Multi-Tenant-Betrieb: Verbindungs-Limits, RLS auf Kanälen prüfen.
- [ ] Gebrandete E-Mail-Templates + Confirmation-Landing-Page (siehe oben).
