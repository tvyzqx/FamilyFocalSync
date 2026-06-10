# Server-Side Notes für FamilyFocalSync

**Erstinstallation auf 7-tm.de Server:** 2026-05-10
**Letzter Stand:** 2026-06-01

> Diese Datei enthält **keine Secret-Werte**, nur Pfade/Topologie und Abläufe.
> Die eigentlichen Schlüssel liegen in `/opt/supabase/.env` (chmod 600).

## Server-Stack
- Supabase: zentrale Multi-App-Instanz unter `/opt/supabase/` — **geteilt** mit
  PackAlong (Schema `packalong`) und Rallye (Schema `rallye`). Nur das Schema
  `familyfocal` gehört zu dieser App; `auth.users` ist instanzweit gemeinsam.
- API-Endpunkt: `https://api.7-tm.de`
- Studio: `https://studio.7-tm.de`
- Schema: `familyfocal`

## Status: LIVE
- **Migrationen 001–028 angewendet** (inkl. Entity-Tabellen, `meta`
  schema_version-Handshake, `device_tokens`, `task_extension_requests`,
  `task_swap_requests`, `task_proposals`, `council_topics.child_id` + scope-aware
  RLS). `meta.schema_version = 22` — additive Sync-Migrationen (025–028) bumpen
  bewusst nicht; die App toleriert fehlende Spalten/Tabellen und synct nach.
- **Council Child Scope (028, 2026-06-01):** neuer `scope = 'child'` auf
  `familyfocal.council_topics` — Eins-zu-eins-Themen zwischen Eltern und einem
  einzelnen Kind, fixiert über die neue Spalte `child_id` (FK auf `profiles`,
  Check-Constraint: child-Scope erzwingt `child_id`). Die SELECT-RLS ist
  scope-bewusst (`council_topics_select_scoped` ersetzt `_select_family`): Eltern
  sehen alle Scopes, ein Kind nur `family` + eigene `child`-Themen, **nicht** die
  `parents`-Themen oder die `child`-Themen von Geschwistern. INSERT verschärft —
  ein Kind kann nicht außerhalb seiner Spur posten.
- **Alle 8 familyfocal Edge Functions deployed**: `bootstrap-family`,
  `generate-join-token`, `join-family`, `check-join-status`,
  `revoke-user-sessions`, `send-notification`, `notify-task-assigned`,
  `delete-account`.
  - `delete-account`: Owner → ganze Familie löschen (CASCADE) + alle
    gebundenen `auth.users`; Member → eigene Mitgliedschaft per
    **Soft-Delete** lösen (`profiles.deleted = true`, `user_id = null`,
    damit der Tombstone über den inkrementellen Sync propagiert) + eigenen
    Auth-User löschen. Owner-Auth-User wird zuletzt und autoritativ
    gelöscht; ein fehlgeschlagener Retry landet selbstheilend im
    Orphan-Branch (entfernt nur die verwaiste `auth.users`-Zeile).
- **Realtime-Publication** für die familyfocal-Tabellen konfiguriert.
- **Push (Phase 7) live** — Relay + Trigger, siehe `docs/push-setup.md`.
- `SUPABASE_PUBLIC_URL=https://api.7-tm.de` gesetzt (QR-Payload erreichbar).
- SMTP-Absendername (`SMTP_SENDER_NAME`/`GOTRUE_SMTP_SENDER_NAME`): `SupabaseTimm`.

## Deploy-Abläufe (für künftige Updates)

> **Wichtig:** Deploy läuft NICHT über `supabase db push` / `supabase functions
> deploy` (kein verlinktes Projekt). Migrationen via `docker exec psql`, Functions
> via Volume-Copy. Siehe auch Memory „Supabase deploy method".

### Migrationen anwenden
```bash
cd /opt/familyfocalsync && git pull
# nur die neuen Dateien anwenden (idempotent prüfen!):
docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < supabase/migrations/0XX_neue_migration.sql
docker exec supabase-db psql -U postgres -c "notify pgrst, 'reload schema';"
```
Tipp: vor nicht-idempotenten Migrationen `select to_regclass('familyfocal.<tabelle>')`
prüfen. Der additive-only-Guard (`scripts/check_migrations.py`) läuft in CI +
pre-commit und schützt den App-Vertrag.

### Edge Functions deployen
```bash
cd /opt/familyfocalsync && git pull
for fn in bootstrap-family generate-join-token join-family check-join-status \
          revoke-user-sessions send-notification notify-task-assigned \
          delete-account; do
  cp -r "supabase/functions/$fn" /opt/supabase/volumes/functions/
done
docker compose -f /opt/supabase/docker-compose.yml up -d functions
```
Service heißt `functions` (Container `supabase-edge-functions`). Die Runtime
serviert pro Request aus dem gemounteten Volume; ein `up -d` genügt nach Env-
Änderungen. **Häufiger Fehler:** eine neue Function vergessen zu kopieren →
500 „could not find appropriate entrypoint" (so geschehen bei
`generate-join-token`, 2026-05-31 nachgezogen).

### Realtime-Publication erweitern (bei neuen Tabellen)
```sql
ALTER PUBLICATION supabase_realtime ADD TABLE familyfocal.<neue_tabelle>;
```

### Push-Secrets / Trigger
Siehe `docs/push-setup.md`. Secrets in `/opt/supabase/.env`
(`FCM_SERVICE_ACCOUNT` base64, `PUSH_RELAY_KEY`, `PUSH_WEBHOOK_SECRET`,
`PUSH_SENDER_URL`, `PUSH_INCLUDE_CONTENT`), durchgereicht im `functions:`-Service.
DB-Webhook-Trigger `familyfocal.tg_notify_task_assigned` auf `tasks` INSERT.

### Smoke-Test
```bash
ANON="<aus /opt/supabase/.env>"
curl -i https://api.7-tm.de/rest/v1/profiles?select=id\&limit=1 \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Accept-Profile: familyfocal"
# Edge Function erreichbar? (nicht-500 = ok, 401 erwartet ohne Eltern-Session)
curl -i https://api.7-tm.de/functions/v1/generate-join-token \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" -d '{}'
```

## Pfade (keine Secret-Werte hier)
| Was | Wo |
|---|---|
| Secrets (ANON/SERVICE_ROLE/JWT, SMTP, Push) | `/opt/supabase/.env` (chmod 600) |
| `PGRST_DB_SCHEMAS`, Redirect-URLs | `/opt/supabase/.env` |
| Edge-Functions (Runtime) | `/opt/supabase/volumes/functions/` |
| Edge-Functions (Source) | `/opt/familyfocalsync/supabase/functions/` |
| Migrationen | `/opt/familyfocalsync/supabase/migrations/` |
| compose / Env-Durchreichung | `/opt/supabase/docker-compose.yml` |
| Hauptdoku zentrale Instanz | `/opt/supabase/ZUGANGSDATEN.md`, `/opt/supabase/docs/MULTI_APP.md` |

## App-Client-Konfiguration (zur Erinnerung)
```dart
// lib/core/supabase/supabase_bootstrap.dart
await Supabase.initialize(
  url: 'https://api.7-tm.de',
  anonKey: '<ANON_KEY>',
  postgrestOptions: PostgrestClientOptions(schema: 'familyfocal'),
);
```
