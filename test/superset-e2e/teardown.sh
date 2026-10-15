#!/usr/bin/env bash
# Remove the local Superset e2e stack completely, and assert it is gone.
# Safe to run twice. Only touches objects this harness created.
set -uo pipefail

cd "$(dirname "$0")"
HERE=$(pwd)

echo "== 1. compose down (containers + named volume) =="
# `down -v` only removes volumes it can attribute to this project, so it must run
# with the compose file present. If the directory is gone we fall back to the
# explicit steps below, which is what guarantees no stale volume survives to
# contaminate the next run (a reused pgdata breaks `superset db upgrade` with a
# duplicate-key error on ab_permission_id_seq).
docker compose --project-directory "$HERE" down -v --remove-orphans 2>/dev/null || true
# belt and braces: remove the project's volumes by name too
for volume in $(docker volume ls --format '{{.Name}}' | grep '^ss-mcp-e2e' || true); do
  docker volume rm "$volume" >/dev/null 2>&1 && echo "   removed volume $volume"
done

echo "== 2. remove any surviving containers by name =="
docker rm -f \
  ss-mcp-e2e-superset-1 \
  ss-mcp-e2e-superset-mcp-1 \
  ss-mcp-e2e-superset-mcp-writer-1 \
  ss-mcp-e2e-db-1 \
  ss-mcp-e2e-redis-1 2>/dev/null || true

echo "== 4. remove the locally built images =="
docker rmi ss-mcp-e2e-superset ss-mcp-e2e-superset-mcp \
          ss-mcp-e2e-superset-mcp-writer 2>/dev/null || echo "   (already gone)"

echo "== 5. remove scratch files =="
rm -f /tmp/e2e-native-filters.json /tmp/e2e.jwt
rm -rf /tmp/ss-e2e

echo
echo "== 6. verify nothing remains =="
leftover=0
if docker ps -a --format '{{.Names}}' | grep -q '^ss-mcp-e2e'; then
  echo "  LEFTOVER containers:"
  docker ps -a --format '{{.Names}}' | grep '^ss-mcp-e2e'
  leftover=1
fi
if docker volume ls --format '{{.Name}}' | grep -q '^ss-mcp-e2e_pgdata'; then
  echo "  LEFTOVER volume: ss-mcp-e2e_pgdata"
  leftover=1
fi
if docker images --format '{{.Repository}}' | grep -q '^ss-mcp-e2e'; then
  echo "  LEFTOVER images:"
  docker images --format '{{.Repository}}' | grep '^ss-mcp-e2e'
  leftover=1
fi

if [ "$leftover" -eq 0 ]; then
  echo "  CLEAN - no e2e containers, volumes, images or files remain"
else
  echo "  WARNING: leftovers listed above"
  exit 1
fi

echo
echo "== 7. disk =="
df -h / | tail -1
