# Apache Superset 6.1.0 — local e2e harness

Reproducible verification of the MCP + REST integration documented in
`docs/librechat-integrations.md` sections 1 and 8. It brings up a **real**
`apache-superset==6.1.0` with its own Postgres and Redis, one process for the web
app and a **separate** process per MCP identity (6.1.0 fixes `MCP_DEV_USERNAME`
per process), seeds the agent role exactly as documented, and then exercises the
native MCP tools and `scripts/superset_dashboard_ctl.py` against it.

Everything is throwaway and self-contained: `teardown.sh` removes the containers,
the named volume, the locally built image and all scratch files, and asserts that
nothing is left. Ports bind to `127.0.0.1` only. Nothing here touches a real
Superset instance — do not point `SUPERSET_URL` at one.

## Prerequisites

- Docker with Compose v2
- ~2 GB free disk, ~2 GB free RAM
- The base image must already be pullable. By default this uses
  `communityfirst/superset-deployment:6.1.0_20260803-1652` (apache-superset 6.1.0,
  already present on the dev host). Override with `--build-arg BASE_IMAGE=...`.

## Run

```bash
cd test/superset-e2e
./run.sh            # build, boot, seed, exercise, measure; leaves the stack up
./run.sh --destroy  # ...then tear everything down automatically
```

`run.sh` prints one line per check. Expected tails:

```
-- MCP (native tools) --     8 passed, 0 failed
-- REST helper --            14 passed, 0 failed
-- cross-role ownership --   3 passed, 0 failed
-- memory --                 no leak signal (cache warm-up, resets on restart)
```

## What it proves

| Claim | How |
|---|---|
| exactly 24 MCP tools exist on 6.1.0 | counts the `Registered MCP tool:` log lines of the real process |
| the documented role grants work | the agent reads its dataset, creates a chart and a dashboard, and is recorded as owner in `dashboard_user` / `slice_user` |
| ownership is the only object boundary | a second, read-only MCP process runs as a different non-owner and is refused |
| `execute_sql` / `save_sql_query` are unreachable | both return an explicit `Permission denied` |
| the REST helper works end to end | every command in docs section 1.11 is executed and its result verified |
| CSRF + session-cookie ordering | the handshake is exercised for real, including over plain `http://` |
| the MCP process does not leak | RSS is sampled across hundreds of calls, then the process is restarted and the curve is shown to re-trace (cache warm-up) rather than continue climbing |

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | base 6.1.0 image + `fastmcp==3.1.0` + the MCP `superset_config.py` |
| `superset_config.py` | MCP block only; the image's own config is exec'd as the base |
| `docker-compose.yml` | Postgres, Redis, Superset web, and two MCP processes (agent + read-only) |
| `seed.py` | creates the two users, the custom roles, the data-access grants and an example dataset |
| `mcp_client.py` | minimal streamable-HTTP MCP client (no SDK), so it mirrors what LibreChat does |
| `agent_checks.py` | the read/write/deny checks against the agent identity |
| `readonly_checks.py` | the cross-role ownership checks |
| `memory_check.py` | RSS sampling, restart, and the plateau comparison |
| `run.sh` | orchestrates all of the above |
| `teardown.sh` | removes everything and asserts it is gone |

## Notes and limits

- Secrets here are dummy values for a disposable stack; never reuse them.
- The stack runs plain HTTP. The TLS/`Referer` path (`WTF_CSRF_SSL_STRICT`) is
  **not** covered — documented as an open gap in docs section 8.4.
- Row-level security and concurrent multi-client load are likewise not covered.
- Absolute memory numbers come from a small instance; the *shape* of the curve is
  the transferable result, not the MiB.
