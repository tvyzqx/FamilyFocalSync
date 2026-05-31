# Server-Side Notes für FamilyFocalSync

**Erstinstallation auf 7-tm.de Server:** 2026-05-10

## Server-Stack
- Supabase: zentrale Multi-App-Instanz unter `/opt/supabase/` (geteilt mit Rally-App + ggf. weiteren)
- API-Endpunkt: `https://api.7-tm.de`
- Studio: `https://studio.7-tm.de`
- Schema: `familyfocal` (vorbereitet, leer)

## Vorgenommen
- Schema `familyfocal` mit Default-Privileges für anon/authenticated/service_role angelegt
- `PGRST_DB_SCHEMAS` in `/opt/supabase/.env` um `familyfocal` ergänzt
- `ADDITIONAL_REDIRECT_URLS` in `/opt/supabase/.env` um `familyfocal://join` und `familyfocal://claim` ergänzt (additiv)
- PostgREST + Auth Container neu erzeugt (greift sofort)
- Repo gecloned nach `/opt/familyfocalsync/` (für künftige `git pull`)

## NOCH NICHT vorgenommen (siehe Phase 0.5 Audit-Findings)
- Migration `010_join_tokens.sql` NICHT angewendet (FK-Refs auf nicht-existente `families`/`profiles`)
- Edge Functions NICHT deployed (referenzieren `profiles` ohne Schema-Qualifizierung)
- Realtime-Publication für `familyfocal`-Tabellen NICHT konfiguriert (keine Tabellen vorhanden)

## Sobald Phase 1 im App-Repo gemerged ist (TODO Server-Side):

### Migrationen anwenden
```bash
cd /opt/familyfocalsync
git pull
for f in supabase/migrations/*.sql; do
  docker cp "$f" supabase-db:/tmp/m.sql
  docker exec supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m.sql
  docker exec supabase-db rm /tmp/m.sql
done
docker exec supabase-db psql -U postgres -c "NOTIFY pgrst, 'reload schema';"
```

### Edge Functions deployen
```bash
# Functions liegen unter /opt/familyfocalsync/supabase/functions/
# In den self-hosted Edge-Runtime-Container kopieren:
for fn in generate-join-token join-family check-join-status; do
  cp -r /opt/familyfocalsync/supabase/functions/$fn /opt/supabase/volumes/functions/
done
docker compose restart edge-functions
```

### Realtime-Publication erweitern
Sobald `familyfocal.profiles`, `familyfocal.tasks` etc. existieren:
```sql
-- in psql als postgres
ALTER PUBLICATION supabase_realtime
  ADD TABLE familyfocal.profiles, familyfocal.tasks, familyfocal.allowance_entries, ...;
-- oder pauschal alle Tabellen im Schema:
ALTER PUBLICATION supabase_realtime ADD TABLES IN SCHEMA familyfocal;
```

### Smoke-Test pro Tabelle
```bash
ANON="<aus /opt/supabase/.env>"
curl "https://api.7-tm.de/rest/v1/profiles?select=id&limit=1" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Accept-Profile: familyfocal"
```

## Server-Credentials & Pfade
| Was | Wo |
|---|---|
| ANON_KEY, SERVICE_ROLE_KEY, JWT_SECRET | `/opt/supabase/.env` (chmod 600) |
| PGRST_DB_SCHEMAS | `/opt/supabase/.env` |
| ADDITIONAL_REDIRECT_URLS | `/opt/supabase/.env` (GoTrue: `GOTRUE_URI_ALLOW_LIST`) |
| Edge-Functions (Runtime) | `/opt/supabase/volumes/functions/` |
| Edge-Functions (Source) | `/opt/familyfocalsync/supabase/functions/` |
| Migrationen | `/opt/familyfocalsync/supabase/migrations/` |
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
