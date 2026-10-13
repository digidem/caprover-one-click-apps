# Spike 6.4: Superset MCP identity and tokens (evidence)

Date: 2026-10-09. Local only: Superset 6.1.0 in a venv, SQLite SUPERSET_HOME, `superset mcp run` on ports 5008 and 5009. Throwaway secrets. Scratch files were in the agent scratchpad (not in the repo). The repo has no `scripts/superset_mint_mcp_token.py` yet; the spike used its own minting script, which is a build task.

## Install (required pins)
`uv pip install "apache-superset[fastmcp]>=6.1.0,<7" PyJWT "flask-caching==2.3.0" "fastmcp==3.1.0"`
- Without `flask-caching==2.3.0`: `superset db upgrade` / `superset init` fail (`ignore_delete_many_errors` TypeError).
- Without `fastmcp==3.1.0`: every token gets 401 `Token validation failed` (`jwt_verifier.py:184` calls `self.jwt.decode`, missing in fastmcp 3.4.8).
- Tested: fastmcp 3.1.0 and 3.4.8. 3.2–3.4.7 untested.

## Identity
- `sub` is read only for a log `client_id` (`jwt_verifier.py:203`). `default_user_resolver` (`mcp_config.py:346-358`) is never called.
- `get_user_from_request()` (`auth.py:176-230`) uses `g.user` if set, else `MCP_DEV_USERNAME` (`auth.py:197`), else raises.
- Without `MCP_DEV_USERNAME`: JWT passes, tool calls fail with "No authenticated user found".
- `MCP_DEV_USERNAME=alpha` process: tokens with sub alpha, gamma, nonexistent all act as alpha.
- `MCP_DEV_USERNAME=gamma` process: same tokens all act as gamma.
- No other path found that sets the MCP user (checked `auth.py:353`, `auth.py:394`, `utils/core.py:1480-1504` not fully traced).
- Conclusion: one MCP process per role.

## Permissions (default roles, 6.1.0)
- Alpha: read and write on Chart, Dashboard, Dataset.
- Gamma: read and write on Chart and Dashboard; read on Dataset only.
- Neither role has `can_execute_sql_query` on SQLLab (`execute_sql` denied for both).
- Gamma `create_virtual_dataset`: denied (`can_write on Dataset`).
- Gamma `generate_dashboard`: dashboard RBAC passes; blocked by dataset access (chart's dataset deleted in the test).
- Alpha `generate_dashboard`: created dashboards, `created_by` = the process user.

## Tokens (HS256, MCP_REQUIRED_SCOPES=mcp:read)
- No token: 401.
- `scope` string `"mcp:read mcp:write"`: 200. `scopes` list only: 401. `scope` plus `scopes`: 200.
- `exp` = now + 365 days: accepted.
- `exp` one hour in the past: 401 `invalid_token`.
- `sub=nonexistent`: passes JWT; identity still the process user.

## Spec consequences
- D10: one process per role, `MCP_DEV_USERNAME` per process.
- A default Gamma can write Dashboards and Charts, so read-only needs a custom role (`can_read` only) and/or `MCP_DISABLED_TOOLS`.
- Risk: `MCP_DEV_USERNAME` is a dev-named setting and the only identity source in 6.1.0.
