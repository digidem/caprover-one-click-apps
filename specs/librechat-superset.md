# Spike 6.4: Superset MCP identity and tokens (evidence)

Date: 2026-10-09. Local only: Superset 6.1.0 in a venv, SQLite SUPERSET_HOME, `superset mcp run` on ports 5008 and 5009. Throwaway secrets. Scratch files were in the agent scratchpad (not in the repo). **Superseded 2026-10-14:** `scripts/superset_mint_mcp_token.py` now exists in this repo, and the version pin was tightened to `apache-superset[fastmcp]==6.1.0` after a source audit of the tag.

## Install (required pins)
`uv pip install "apache-superset[fastmcp]==6.1.0" PyJWT "flask-caching==2.3.0" "fastmcp==3.1.0"`
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
- D10: one process per `MCP_DEV_USERNAME` identity. Note this is a property of
  our configuration, not a law of MCP: 6.1.0's `get_user_from_request()`
  (`auth.py:176`) prefers an already-set `g.user` (e.g. Preset workspace
  middleware) and only then `MCP_DEV_USERNAME`. A `default_user_resolver()`
  function exists at `mcp_config.py:346`, but **no 6.1.0 code path calls it** —
  dead code in this tag — and there is no `MCP_USER_RESOLVER` setting. So the
  JWT `sub` does not select the user in our stock deployment.
- **There is no per-tool allow/deny list in 6.1.0**: `MCP_DISABLED_TOOLS` has
  zero occurrences in the entire `superset/` package at tag `6.1.0` (verified
  across all 1176 `.py` files); it appears in `mcp_config.py` from `7.0.0rc1`.
  Setting it on 6.1.0 is a silent no-op. The tool surface is fixed at **24
  tools**, and the only control over the agent is the FAB role.
- Scopes are a **global JWT admission requirement only** (`mcp_config.py:312`
  feeds `MCP_REQUIRED_SCOPES` to the verifier). 6.1.0 has no per-tool scope
  enforcement (no `_token_scope_allows`, no `superset:<resource>:<action>` map;
  both 7.0). `mcp:read` alone does NOT make the agent read-only.
- Tool search (`MCP_TOOL_SEARCH_CONFIG`, BM25, `include_schemas=False`,
  `always_visible=[health_check, get_instance_info]`) is the default in 6.1.0
  (`mcp_config.py:277`). Search results are NOT permission-filtered in 6.1.0
  (`RBACToolVisibilityMiddleware` is 7.0): a tool can be listed and then 403.
- **6.1.0 has no `raise_for_editorship`** (zero occurrences in the whole
  package; it appears from 7.x). 6.1.0 enforces **ownership only**
  (`raise_for_ownership`, `security/manager.py:3125`). Every mutation path we
  use checks it: MCP `update_chart` -> `commands/chart/update.py:119`, MCP
  `add_chart_to_existing_dashboard` -> its own call at
  `dashboard/tool/add_chart_to_existing_dashboard.py:340`, REST dashboard PUT ->
  `commands/dashboard/update.py:94`, REST chart DELETE ->
  `commands/chart/delete.py:68`, REST dataset DELETE ->
  `commands/dataset/delete.py:55`.
- **6.1.0 has no soft delete** (zero occurrences of `SOFT_DELETE` or
  `SoftDeleteMixin` in the package). Chart/dashboard/dataset deletes are hard
  deletes. Trash/restore is a later feature; do not describe 6.1.0 deletes as
  recoverable.
- CSRF is enabled: `WTF_CSRF_ENABLED = True` (`config.py:305`),
  `BaseSupersetApiMixin.csrf_exempt = False` (`views/base_api.py:194`), and the
  `/api/v1/{dashboard,chart,dataset}` CRUD endpoints are not in
  `WTF_CSRF_EXEMPT_LIST`. Any REST helper must carry a cookie session and an
  `X-CSRFToken` fetched from `GET /api/v1/security/csrf_token/`.
- MCP calls do **not** need to be issued sequentially. `mcp_auth_hook` pushes a
  fresh app context per call, clears stale `g.user`, and rolls the session back
  on error (`auth.py:390`, `auth.py:283`, `auth.py:357`). No sequential-call
  requirement is documented or reproducible from the tag.
