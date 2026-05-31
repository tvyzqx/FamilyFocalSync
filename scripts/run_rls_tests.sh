#!/usr/bin/env bash
# Run the RLS cross-tenant test suite against the familyfocal schema.
#
# Side-effect free: the SQL wraps everything in a transaction that ROLLs BACK,
# so it never commits and is safe to run against a live database.
#
# Usage:
#   scripts/run_rls_tests.sh                 # docker exec into $CONTAINER (default supabase-db)
#   CONTAINER=my-db scripts/run_rls_tests.sh
#   DSN=postgres://... scripts/run_rls_tests.sh   # run against a DSN with psql directly
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
sql="$repo_root/supabase/tests/rls_cross_tenant.sql"

if [[ -n "${DSN:-}" ]]; then
  exec psql "$DSN" -X -f "$sql"
fi

container="${CONTAINER:-supabase-db}"
docker exec -i "$container" psql -U postgres -d postgres -X < "$sql"
