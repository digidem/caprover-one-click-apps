#!/usr/bin/env bash
# Build, boot, seed and exercise the local Superset 6.1.0 e2e stack.
#
# Usage:
#   ./run.sh              # run everything, leave the stack up for inspection
#   ./run.sh --destroy    # run everything, then tear the stack down
#   ./run.sh --keep       # only boot + seed, skip the checks
#
# Ports bind to 127.0.0.1 only. Nothing here talks to a real Superset instance.
set -uo pipefail

cd "$(dirname "$0")"
HERE=$(pwd)
DESTROY=0
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --destroy) DESTROY=1 ;;
    --keep) KEEP=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

COMPOSE=(docker compose --project-directory "$HERE")
WEB_URL="http://127.0.0.1:18088"
MCP_URL="http://127.0.0.1:15008"
MCP_WRITER_URL="http://127.0.0.1:15009"
JWT_SECRET="e2e-shared-secret-not-real-000000"

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { printf '\n== %s ==\n' "$*"; }

cleanup() {
  local status=$?
  if [ "$DESTROY" -eq 1 ]; then
    echo
    bash "$HERE/teardown.sh"
  else
    echo
    echo "stack left running. Inspect:"
    echo "  Superset web : $WEB_URL"
    echo "  MCP (agent)  : $MCP_URL/mcp"
    echo "  MCP (writer) : $MCP_WRITER_URL/mcp"
    echo "tear it down with: $HERE/teardown.sh"
  fi
  return $status
}
trap cleanup EXIT

note "1/7 build the e2e image"
"${COMPOSE[@]}" build superset || fail "image build failed"

note "1b/7 start from a clean slate"
# A leftover pgdata from an earlier run breaks `superset db upgrade` (duplicate
# key on ab_permission_id_seq), so never reuse one. The removal must happen with
# nothing from the previous stack still running, so that is dealt with first:
# `docker volume rm` fails while a container holds the volume, and that failure
# must not be swallowed.
for container in $(docker ps -aq -f name='ss-mcp-e2e' || true); do
  docker rm -f "$container" >/dev/null 2>&1 || true
done
if docker volume ls --format '{{.Name}}' | grep -q '^ss-mcp-e2e_pgdata'; then
  if docker volume rm ss-mcp-e2e_pgdata >/dev/null 2>&1; then
    echo "  removed a stale pgdata volume from a previous run"
  else
    fail "cannot remove the stale ss-mcp-e2e_pgdata volume; something still holds it (see docker ps -a)"
  fi
fi

note "2/7 start Postgres, Redis, Superset web and the two MCP processes"
"${COMPOSE[@]}" up -d || fail "compose up failed"

note "3/7 wait for the web app"
for _ in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$WEB_URL/health" 2>/dev/null || true)
  [ "$code" = "200" ] && { echo "  healthy"; break; }
  sleep 5
done
[ "$(curl -s -o /dev/null -w '%{http_code}' "$WEB_URL/health" 2>/dev/null)" = "200" ] \
  || fail "Superset web never became healthy"

note "4/7 wait for both MCP processes"
for url in "$MCP_URL" "$MCP_WRITER_URL"; do
  for _ in $(seq 1 24); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/mcp" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"tools/list","id":1}' 2>/dev/null || true)
    [ "$code" = "401" ] && { echo "  $url ready"; break; }
    sleep 5
  done
  [ "$code" = "401" ] || fail "MCP at $url never became ready"
done

note "5/7 count the registered MCP tools"
tools=$("${COMPOSE[@]}" logs superset-mcp 2>/dev/null \
  | grep -oE 'Registered MCP tool: [a-z_]+' | sort -u | wc -l)
echo "  distinct tools registered: $tools"
if [ "$tools" -eq 24 ]; then
  echo "  PASS 24 tools, matching the documented 6.1.0 set"
else
  echo "  WARN expected 24, saw $tools - docs section 8.1 may be stale"
fi

note "6/7 seed the identities, roles, data access and example dataset"
# The copy is part of the step, not best-effort: a silent cp failure leaves the
# container running the seed.py shipped in the image build, which can diverge from
# this checkout (this is exactly how a stale seed was run once).
"${COMPOSE[@]}" cp seed.py superset:/tmp/seed.py || fail "could not copy seed.py"
"${COMPOSE[@]}" exec -T superset python /tmp/seed.py || fail "seeding failed"

# The seed claims to be done when the dataset row exists, but generate_chart fails
# on a dataset with no cached columns. Assert the state the checks depend on, so a
# silent metadata miss is a seeding failure and not a mystery in step 7.
# The app banner goes to stdout, so take the LAST line of output, not all of it.
columns=$("${COMPOSE[@]}" exec -T superset python - <<'PY' 2>/dev/null | tail -1
from superset import create_app
from superset.extensions import db
app = create_app()
with app.app_context():
    from superset.connectors.sqla.models import SqlaTable
    ds = db.session.query(SqlaTable).filter_by(table_name="e2e_frota").first()
    print(0 if ds is None else len(ds.columns))
PY
) || fail "seeded state could not be verified"
case "$columns" in
  ''|*[!0-9]*) fail "seeded state could not be read (got: '$columns')" ;;
esac
[ "$columns" -ge 4 ] || \
  fail "seeding incomplete: e2e_frota has $columns cached columns, the checks need at least 4"
echo "  seeded: e2e_frota has $columns cached columns"

if [ "$KEEP" -eq 1 ]; then
  note "skipping the checks (--keep)"
  exit 0
fi

note "7/7 exercise the integration"
export AGENT_PASSWORD="agent-pw-local-only"
export WRITER_PASSWORD="writer-pw-local-only"
export MCP_URL MCP_WRITER_URL WEB_URL
export REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"

mint_token() {  # <username> -> JWT on stdout
  ( cd "$REPO_ROOT" && MCP_JWT_SECRET="$JWT_SECRET" python3 scripts/superset_mint_mcp_token.py \
      --sub "$1" --iss superset --aud superset --scopes 'mcp:read' --days 7 )
}

export AGENT_TOKEN WRITER_TOKEN
AGENT_TOKEN=$(mint_token librechat-agent)
WRITER_TOKEN=$(mint_token e2e-writer)

status=0
( cd "$HERE" && python3 agent_checks.py )     || status=1
( cd "$HERE" && python3 readonly_checks.py )  || status=1

# the helper needs its own env
export SUPERSET_URL="$WEB_URL"
export SUPERSET_USERNAME="librechat-agent"
export SUPERSET_PASSWORD="$AGENT_PASSWORD"
( cd "$HERE" && python3 rest_checks.py )      || status=1

( cd "$HERE" && python3 memory_check.py )     || status=1

echo
if [ "$status" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED (see above)"
fi
exit $status
