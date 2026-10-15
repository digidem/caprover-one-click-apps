#!/usr/bin/env bash
# Run the REST helper checks against the e2e stack through a TLS-terminating
# front, i.e. with the https URL the docs tell operators to use.
#
# Why this exists: docs/librechat-integrations.md 8.4 lists HTTPS as NOT verified.
# The helper's CSRF/session handshake and Superset's `Referer` check are both
# TLS-sensitive, so "it worked over http" is not evidence for production. nginx
# terminates a self-signed cert and forwards to the plain-HTTP superset container,
# which is the URL shape that matters, with no change to the helper.
#
# Usage:
#   ./tls_check.sh            # bring the stack up, run, leave it running
#   ./tls_check.sh --destroy  # bring the stack up, run, tear everything down
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

DESTROY=0
for arg in "$@"; do
  case "$arg" in
    --destroy) DESTROY=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { printf '\n== %s ==\n' "$*"; }

note "1/4 bring the stack up (same harness as run.sh)"
REPO_ROOT="$REPO" ./run.sh --keep

# ------------------------------------------------------------------- the front
note "2/4 start nginx terminating a self-signed cert, proxying to superset:8088"
if [[ ! -f certs/localhost.crt ]]; then
  mkdir -p certs
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout certs/localhost.key -out certs/localhost.crt -subj "/CN=localhost" >/dev/null 2>&1
  chmod 600 certs/localhost.key
fi

docker compose -f docker-compose.tls.yml up -d --no-build tls

for _ in $(seq 1 60); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:18443/health || true)
  [[ "$code" == "200" ]] && break
  sleep 1
done
[[ "${code:-}" == "200" ]] || fail "the TLS front never became healthy"
echo "  https://127.0.0.1:18443 -> http://superset:8088 is ready"

# The helper verifies the transport but not the certificate chain, so a
# self-signed cert is fine: what is under test is the app-level handshake
# (session cookie + CSRF token + Referer), not PKI.
export SUPERSET_URL="https://localhost:18443"
export SUPERSET_USERNAME="librechat-agent"
export SUPERSET_PASSWORD="agent-pw-local-only"
export MCP_URL="http://127.0.0.1:15008"
export AGENT_TOKEN="$(cd "$REPO" && MCP_JWT_SECRET='e2e-shared-secret-not-real-000000' \
  python3 scripts/superset_mint_mcp_token.py --sub librechat-agent --iss superset \
  --aud superset --scopes 'mcp:read' --days 7)"

note "3/4 the helper must log in, get a CSRF token and mutate over https"
login_output="$(python3 "$REPO/scripts/superset_dashboard_ctl.py" show dashboard 1 2>&1 || true)"
echo "$login_output" | grep -q "owned by LibreChat Agent" \
  || fail "the helper could not read a dashboard over https: $(echo "$login_output" | tail -2)"
echo "  PASS  login and read work over https"

# The three properties that differ from the plain-http run, each as a real call
# instead of a string match:
#   1. the mutation succeeds (handshake complete)
#   2. no CSRF rejection (the token rides the Secure cookie)
#   3. no Referer rejection (FAB checks the Origin on every POST)
rename_output="$(python3 "$REPO/scripts/superset_dashboard_ctl.py" \
  rename-dashboard 1 --title "TLS probe" 2>&1 || true)"
echo "$rename_output" | grep -qi "csrf" && fail "CSRF rejected over https: $rename_output"
echo "$rename_output" | grep -qi "referer\|origin" && fail "Referer rejected over https: $rename_output"
echo "$rename_output" | grep -q '"ok": true' \
  || fail "the mutation did not take over https: $(echo "$rename_output" | tail -2)"
echo "  PASS  a mutation over https (no CSRF rejection, no Referer rejection)"

note "4/4 rerun the full REST helper suite against the https URL"
status=0
python3 rest_checks.py || status=1

docker compose -f docker-compose.tls.yml down --remove-orphans >/dev/null 2>&1 || true

echo
if (( status == 0 )); then
  echo "TLS CHECKS PASSED - the https path in 8.4 is now covered"
else
  echo "TLS CHECKS FAILED (see above)"
  status=1
fi

if (( DESTROY )); then
  note "tearing the stack down"
  ./teardown.sh
fi
exit $status
