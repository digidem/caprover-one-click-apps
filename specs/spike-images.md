# Spike 6.1–6.3: image facts (local Docker only, no CapRover)

Date: 2026-10-09. Anonymous pulls. Swarm not initialised. CapRover command delivery NOT tested (needs a real CapRover).

## librechat/librechat-api:v0.8.8
- Entrypoint `["docker-entrypoint.sh"]`, Cmd `["node","server/index.js"]`, WorkingDir `/app/api`, User root (uid 0), port 3080.
- `base64`, `tail`, `sleep` present. `/app/librechat.yaml` absent; writable as root.
- `require('librechat-data-provider').configSchema.strict().safeParse` and `require('js-yaml').load` both functions.
- Minimal config (version, one custom endpoint, `mcpServers.postgres` sse with `${PG_MCP_URL}`) passes `safeParse`.
- Invalid MCP `type: bogus` fails `safeParse`.
- Scripts outside `/app` need `NODE_PATH=/app/node_modules:/app/api/node_modules`.
- Server boot not tested (needs Mongo).

## crystaldba/postgres-mcp:0.3.0
- Newest semver on Docker Hub (2025-05-16); `latest` is the same build.
- Entrypoint `["/app/docker-entrypoint.sh","postgres-mcp"]`, User root, port 8000.
- `/bin/sh` (dash), `tail`, `sleep`, `base64`, `cat` present.
- Flags: `--access-mode {unrestricted,restricted}`, `--transport {stdio,sse}`, `--sse-host` (default localhost), `--sse-port` (default 8000). Default access mode not shown in help.
- The entrypoint adds `--sse-host=0.0.0.0` only when it runs with `--transport=sse`.
- Empty `DATABASE_URI` with the default entrypoint: exit 1 (`No database URL provided`). Does NOT idle.
- With a DSN to a throwaway postgres: `Uvicorn running on http://0.0.0.0:8000`; `GET /sse` returned 200 `text/event-stream`.
- Wrapper `sh -c 'if [ -z "${DATABASE_URI:-}" ]; then echo "pg-mcp disabled"; exec tail -f /dev/null; fi; exec postgres-mcp --access-mode=restricted --transport=sse --sse-host=0.0.0.0 --sse-port=8000'`: empty DSN → running, exit 0; DSN set → serves on 0.0.0.0:8000.

## mongo:8.0.20
- Tag exists on Docker Hub (updated 2026-04-16), amd64 and arm64. Latest 8.0.x patch not checked. AVX requirement not tested.

## Startup command (inferred, NOT verified)
- Swarm `Command` replaces ENTRYPOINT; `Args` replaces CMD (inferred from docs, not run).
- With `Command: sh -c …`, both the librechat entrypoint and CMD are dropped, so the boot script must end with `exec node server/index.js`.
- With `Command: sh -c …`, the postgres-mcp entrypoint's auto `--sse-host` is dropped, so the wrapper passes it itself.
- Still open: spike 6.3 / 6.3a on a real CapRover.
