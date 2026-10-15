# SPEC — LibreChat one-click app with optional MCP auto-connect

Status: BUILT (2026-10-12) — spec, boot script, template, logo, mint script, docs, CI workflow all in the worktree; generator test ALL CHECKS PASSED (16 checks); remaining: T99 live acceptance on production (needs user go-ahead). Reviews: Codex final findings fixed ·    Date: 2026-10-09 · Branch/worktree: `librechat` @ `../caprover-one-click-apps-librechat` (from `origin/master` c3c998f)

## 1. Goal

Add `public/v4/apps/librechat.yml` (+ `public/v4/logos/librechat.png`) to this CapRover app store. One install gives a working LibreChat. Optional one-click variables, when filled, make LibreChat connect automatically to these MCP servers:

| MCP | Where the MCP server runs | LibreChat side |
|---|---|---|
| PostgreSQL | sidecar service in this template (`$$cap_appname-pg-mcp`) | `sse` → `http://srv-captain--$$cap_appname-pg-mcp:8000/sse` |
| Windmill | built into the user's existing Windmill | `streamable-http` → `<windmill>/api/mcp/w/<ws>/mcp`, `Authorization: Bearer` header |
| Superset (**primary integration**) | `superset mcp run` next to the user's existing Superset (not in this template) | `streamable-http` → user-given URL, optional bearer token |

The template recommends **Tinfoil** (https://tinfoil.sh, private inference in attested enclaves) as the LLM provider. Tinfoil is OpenAI-compatible, so it is wired as a LibreChat custom endpoint with a configurable URL and API key.

Every MCP variable is optional. Empty variables mean the MCP entry is left out entirely. Nothing breaks, and the user sees no dead server in the UI.

Out of scope for v1: KoboToolbox (dropped by decision 2026-10-09), Meilisearch search, RAG API with pgvector, the LibreChat admin panel, the nginx client (CapRover handles ingress), and SSO.

## 2. Verified facts (drive the design)

LibreChat (source checked @ `LibreChat-AI/LibreChat` e1dfc10, tag `v0.8.8`):
- The repo moved from `danny-avila/LibreChat` to `LibreChat-AI/LibreChat`. Official image: `docker.io/librechat/librechat-api` (anonymous pull works; tags incl. `v0.8.8`; https://hub.docker.com/r/librechat/librechat-api). The `tag-images.yml` workflow publishes `librechat` and `librechat-api` with release tags (`v0.8.8`). The compose files use `*-dev` images, which we will not use.
- Image RESOLVED: use `docker.io/librechat/librechat-api:v0.8.8` (pin the tag, never `latest`). Fallback: `registry.librechat.ai/librechat-ai/librechat-api` redirects to `ghcr.io/librechat-ai/librechat-api` (anonymous `tags/list` works). Image facts: `WORKDIR /app/api`, `CMD node server/index.js`, `EXPOSE 3080` (`Dockerfile.multi` @ v0.8.8). Default config `/app/librechat.yaml`; `CONFIG_PATH` overrides (`packages/api/src/app/loader.ts:174`). `configSchema` is exported by `librechat-data-provider` (`packages/data-provider/src/config.ts:3125`), CJS dist copied into the image. Live `node -e "require(...)"` inside the image: verified by local spike 6.1 (`specs/spike-images.md`); in-image boot not tested.
- Only api and mongo are required. `SEARCH=false` is the default, and RAG is opt-in through `RAG_API_URL`.
- The api image is `WORKDIR /app/api`, `EXPOSE 3080`, `CMD ["node","server/index.js"]`. The config lives at `/app/librechat.yaml`, and `CONFIG_PATH` overrides it. Node is 24-alpine with `npx` and `uv`.
- `librechat.yaml` resolves `${VAR}` from `process.env` for YAML-defined MCP `url`, `headers`, `env` and `args` (`extractEnvVariable`, `packages/api/src/utils/env.ts`).
  - An unset variable stays as the literal `${VAR}`; it does not become empty. So an empty variable cannot disable an entry, and entries must be generated conditionally.
  - Infrastructure secrets (`JWT_SECRET`, `JWT_REFRESH_SECRET`, `CREDS_KEY`, `CREDS_IV`, `MEILI_MASTER_KEY`, `MONGO_URI`, …) are never interpolated, which is good.
- MCP types are `stdio`, `sse`, `streamable-http` and `websocket`. Useful fields are `headers`, `timeout`, `initTimeout`, `startup`, `chatMenu` and `serverInstructions`. A connection failure is logged ("Failed to connect after N attempts"). A config validation error exits the process.
- `CREDS_KEY` is 64 hex characters and `CREDS_IV` is 32 hex. If either is blank, LibreChat auto-generates them into a temp file, which breaks encrypted credentials on redeploy. They must be fixed variables.

CapRover one-click (server source; from source reading, NOT verified on a live server; gated by spike 6.3/6.3a):
- `$$cap_*` placeholders are replaced by plain string substitution on the JSON-stringified template. Values are not escaped, so `"`, `\` or a newline breaks the deploy. Every free-text variable needs a strict `validRegex`.
- An empty variable becomes `''`. Services cannot be conditional, because every service is always deployed.
- `depends_on` only sets deploy order; there is no readiness wait. It must not name an app outside the template.
- If `image` is set, `dockerfileLines` is ignored. When `dockerfileLines` is used, substituted values are baked into image layers, so no secrets may go there.
- Precedent: upstream `lemmy.yml` generates a config file through `command: sh -c 'printf … > file; …'`.

MCP servers:
- Postgres: `crystaldba/postgres-mcp` (MIT, active). Flags confirmed: `--access-mode=restricted|unrestricted`, `--transport=sse` (default stdio), env `DATABASE_URI`, SSE example port 8000 (https://github.com/crystaldba/postgres-mcp). `restricted` = read-only transactions with an execution time limit; still recommend a read-only DB role. Default access mode: UNVERIFIED; pass it explicitly. Pinned `0.3.0`: newest semver on Docker Hub (2025-05-16); `latest` is the same build (spike 6.2). The reference server `@modelcontextprotocol/server-postgres` is archived and has no security fixes, so we reject it.
- Windmill MCP (built in):
  - Endpoint `<base>/api/mcp/w/<ws>/mcp` (streamable HTTP; `/sse` deprecated). Minimum Windmill version for the MCP endpoints: v1.484.0 (https://github.com/windmill-labs/windmill/releases/tag/v1.484.0); latest checked v1.828.0. Pin >= 1.484.0. Token via `Authorization: Bearer <token>` header; admins can refuse `?token=`. Token creation: user settings > Tokens > Generate MCP URL.
  - Multi-workspace gateway `<base>/api/mcp/gateway` (adds `list_workspaces`; `workspace_id` required). Access is gated by workspace membership.
  - Tools confirmed (https://www.windmill.dev/docs/core_concepts/mcp): listScripts, createScript, updateScript (deploys a new version), getScriptByPath, deleteScriptByPath (admin only), deleteScriptByHash (admin only), runScriptByPath, runScriptPreviewAndWaitResult, listFlows, getFlowByPath, createFlow, updateFlow, deleteFlowByPath, runFlowByPath, getJob, getJobLogs, listJobs, listQueue, listSchedules, getSchedule, createSchedule, updateSchedule, deleteSchedule; plus resources, variables and workers.
  - Token scopes exist: `{domain}:{action}[:{path}]`, e.g. `scripts:write:f/production/*`; write includes read; a Read-only toggle and path restriction exist (https://www.windmill.dev/docs/core_concepts/user_tokens). MCP tool exposure can be limited to chosen folders (MCP docs). "Disable token in MCP URLs" is a superadmin setting; our Bearer header plan is unaffected.
  - `createSchedule` fields (OpenAPI `NewSchedule`): `path`, `schedule` (6-field cron with a seconds field, e.g. `"0 0 12 * * *"`), `timezone` (IANA), `script_path`, `is_flow`, `args`, `enabled`, plus `on_failure`/`on_success`/`on_recovery`.
- Superset MCP (official, built into Superset):
  - Install (spike 6.4): `uv pip install "apache-superset[fastmcp]==6.1.0" PyJWT "flask-caching==2.3.0" "fastmcp==3.1.0"`. Both pins are required: without `flask-caching==2.3.0`, `superset init` fails; without `fastmcp==3.1.0`, every token gets 401. fastmcp 3.2–3.4.7 is untested. First stable release with MCP: Superset 6.1.0 (PyPI 2026-05-13); 6.0.0 has no `mcp_service` (https://github.com/apache/superset/blob/6.1.0/superset/cli/mcp.py, UPDATING.md). Run: `superset mcp run --host 0.0.0.0 --port 5008` (CLI defaults to 127.0.0.1:5008, so bind explicitly). Endpoint `/mcp`, streamable HTTP.
  - Docs at https://superset.apache.org/admin-docs/configuration/mcp-server/ are marked "Next". Version pin: `apache-superset==6.1.0` exact (the tested version; reproducible).
  - Auth: `MCP_AUTH_ENABLED = True`, `MCP_JWT_ALGORITHM` ("RS256" default or "HS256"), `MCP_JWT_SECRET` (HS256), `MCP_JWT_PUBLIC_KEY` or `MCP_JWKS_URI` (RS256), `MCP_JWT_ISSUER`, `MCP_JWT_AUDIENCE`, `MCP_REQUIRED_SCOPES` (e.g. `mcp:read`, `mcp:write`). HS256 confirmed in code. `exp` is always validated (`ExpiredTokenError` in `jwt_verifier.py`); no max `exp` and no leeway found, so long-lived tokens are allowed by code. Service-token issuance is undocumented: we write our own minting script. Verified (spike 6.4): a 1-year `exp` is accepted; an expired token gets 401 `invalid_token`; the token must carry a `scope` string (a `scopes` list alone gets 401).
  - RBAC: `MCP_RBAC_ENABLED` default True. Each tool checks FAB permissions. Dashboard read tools need can_read on Dashboard. Dashboard write tools (generate_dashboard, add_chart_to_existing_dashboard, update/delete) need can_write on Dashboard. `execute_sql` needs can_execute_sql_query on SQLLab. Chart write tools need can_write on Chart. Dataset writes (create_virtual_dataset) need can_write on Dataset.
  - Tools in **6.1.0**: exactly **24**, verified from the `@tool` registrations at tag `6.1.0`. Chart (8): `list_charts`, `get_chart_info`, `get_chart_data`, `get_chart_preview`, `generate_chart`, `update_chart`, `update_chart_preview`, `get_chart_type_schema`. Dashboard (4): `list_dashboards`, `get_dashboard_info`, `generate_dashboard`, `add_chart_to_existing_dashboard`. Dataset (3): `list_datasets`, `get_dataset_info`, `create_virtual_dataset`. Database (2): `list_databases`, `get_database_info`. SQL Lab (3): `execute_sql`, `open_sql_lab_with_context`, `save_sql_query`. Explore (1): `generate_explore_link`. System (3): `health_check`, `get_instance_info`, `get_schema`. `get_dashboard_data` is **not** a 6.1.0 tool (it is 7.x), as are `manage_native_filters`, `remove_chart_from_dashboard`, `delete_chart`, `delete_dashboard`, `update_dashboard`, `update_dataset`, `query_dataset`, `list_metrics`, `get_table`, `get_catalog`.
  - **No per-tool allow/deny list exists in 6.1.0.** `MCP_DISABLED_TOOLS` has zero occurrences in the whole 6.1.0 `superset/` package (verified across 1176 `.py` files); it appears in `mcp_config.py` from `7.0.0rc1`. Setting it is a silent no-op. The FAB role of `MCP_DEV_USERNAME` is the only control.
  - Scopes (`MCP_REQUIRED_SCOPES`) are a global JWT admission requirement only. 6.1.0 has no per-tool scope enforcement (`_token_scope_allows` and `superset:<resource>:<action>` are 7.0), so `mcp:read` does not make a token read-only.
  - Tool search is the default in 6.1.0 (`mcp_config.py:277`): BM25, `max_results=5`, `include_schemas=False`, `always_visible=[health_check, get_instance_info]`. Search/list results are NOT permission-filtered in 6.1.0 (no `RBACToolVisibilityMiddleware`), so "visible in search" != "authorized" — RBAC is checked at call time.
- Identity (spike 6.4): Superset 6.1.0 ignores the token `sub`. Each process runs as the user named in `MCP_DEV_USERNAME`, the only identity source found. The name suggests dev-only; it is the sole option in 6.1.0, so v1 relies on it and this is a known risk.
  - Dashboard mutation refuses externally managed dashboards (`managed_externally`).

Tinfoil:
- Base URL `https://inference.tinfoil.sh/v1` CONFIRMED (https://docs.tinfoil.sh/sdk/direct-api-access).
- Model IDs: `kimi-k3`, `glm-5-3` (not `glm-5.3`), `gpt-oss-120b`, `gemma4-31b`, `llama3-3-70b`, `deepseek-v4-1-flash` (experimental). `glm-5-3-flash` was removed from the catalog on 2026-10-09: do not use.
- `GET /v1/models` returned 200 without auth in a live probe but is undocumented. Do not rely on `models.fetch: true`; set `models.default` explicitly. Title generation: spike 6.7 (2026-10-09): a title-style chat call returns `finish_reason: stop` and a 5-word title, but `gpt-oss-120b` spends tokens on reasoning first. With `max_tokens: 60` the content was `null`; with 400 it returned the title. LibreChat's own title `max_tokens` is unverified.
- A plain OpenAI client does NOT verify enclave attestation (https://docs.tinfoil.sh/tutorials/coding-agents; direct-access docs: no cryptographic proof, no protection against man-in-the-middle). The Tinfoil SDK or Tinfoil Proxy performs it (https://docs.tinfoil.sh/sdk/python-sdk). v1 accepts this gap (D6).

## 3. Design

### 3.1 Services (all names follow repo convention)

| Service | Image | Exposed | Notes |
|---|---|---|---|
| `$$cap_appname` | `docker.io/librechat/librechat-api:$$cap_librechat_version` | web, `containerHttpPort: '3080'` | generates config at start, then `exec node server/index.js` |
| `$$cap_appname-mongodb` | `mongo:$$cap_mongo_version` (default `8.0.20`; tag exists per spike 6.1; latest 8.0.x patch to confirm) | `notExposeAsWebApp` | volume `$$cap_appname-mongo-data:/data/db`; **auth on** via `MONGO_INITDB_ROOT_USERNAME=librechat` and `MONGO_INITDB_ROOT_PASSWORD=$$cap_mongo_password`. `MONGO_INITDB_ROOT_*` applies only on first init: changing `$$cap_mongo_password` later breaks `MONGO_URI`. To rotate, run `db.changeUserPassword` first, then update `MONGO_URI`. |
| `$$cap_appname-pg-mcp` | `crystaldba/postgres-mcp:0.3.0` | `notExposeAsWebApp` | `command` is a wrapper (spike 6.2): `sh -c 'if [ -z "${DATABASE_URI:-}" ]; then echo "pg-mcp disabled"; exec tail -f /dev/null; fi; exec postgres-mcp --access-mode=restricted --transport=sse --sse-host=0.0.0.0 --sse-port=8000'`. The image itself exits 1 on an empty `DATABASE_URI`, so the wrapper is required. `--sse-host` is passed explicitly because the image entrypoint adds it only when it runs. |

Superset is NOT a service in this template: its MCP process runs next to the user's Superset. The Windmill MCP is external too (built into Windmill). Only the Postgres MCP service is deployed here.

Volumes on the api service: `$$cap_appname-uploads:/app/uploads`, `$$cap_appname-images:/app/client/public/images` and `$$cap_appname-logs:/app/api/logs`. The image runs from `/app/api`, and the logger writes to `<cwd>/logs` (`packages/data-schemas/src/config/utils.ts`).

### 3.2 Service environment contract

`$$cap_appname` (api):

| env | value |
|---|---|
| `MONGO_URI` | `mongodb://librechat:$$cap_mongo_password@srv-captain--$$cap_appname-mongodb:27017/LibreChat?authSource=admin` |
| `HOST` / `PORT` / `NODE_ENV` | `0.0.0.0` / `3080` / `production` |
| `DOMAIN_CLIENT`, `DOMAIN_SERVER` | `https://$$cap_appname.$$cap_root_domain`. Change both after install if you use a custom domain; the `end` instructions say so. |
| `TRUST_PROXY` | `1` (one hop: CapRover nginx) |
| `CREDS_KEY`, `CREDS_IV`, `JWT_SECRET`, `JWT_REFRESH_SECRET` | the fixed `$$cap_*` values (§3.4) |
| `ALLOW_REGISTRATION` | `$$cap_allow_registration` |
| `SEARCH` | `false` |
| `LLM_NAME`, `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_DEFAULT_MODEL` | from §3.4 |
| `PG_MCP_ENABLED` | `$$cap_pg_mcp_enabled` (`0`/`1`) |
| `PG_MCP_URL` | `http://srv-captain--$$cap_appname-pg-mcp:8000/sse` (fixed) |
| `WINDMILL_MCP_URL`, `WINDMILL_MCP_TOKEN`, `SUPERSET_MCP_URL`, `SUPERSET_MCP_TOKEN` | from §3.4 |

`$$cap_appname-pg-mcp` gets `DATABASE_URI=$$cap_pg_mcp_database_uri`. The DSN never goes into the api container.

### 3.3 Config generation (core mechanism)

The api service `command` is a YAML array, `['sh', '-c', <script>]`. CapRover maps an array straight to the Swarm `ContainerSpec.Command`; a string goes through a simple quote-splitting regex (`DockerComposeToServiceOverride.ts`). The script runs `set -eu`. On each start it:
1. writes the base `librechat.yaml` (`version`, `cache: true`, interface defaults) and `endpoints.custom[0]`:
   - `name` and `models.default[0]` are written as **concrete, single-quoted YAML scalars** from `LLM_NAME` / `LLM_DEFAULT_MODEL`. LibreChat does not interpolate `${}` in `name` or `models.default` (`packages/api/src/endpoints/custom/config.ts:41-44`, `endpoints/config/models.ts:282-285`), and `[${VAR}]` is invalid YAML. Their regexes (§3.4) allow no quotes or other characters that need escaping;
   - `baseURL: '${LLM_BASE_URL}'` (default `https://inference.tinfoil.sh/v1`), `models.fetch: false`, `titleConvo: false` (v1 default; spike 6.7 shows titles work only with enough output tokens, and LibreChat's title budget is unverified);
   - `apiKey: '${LLM_API_KEY}'` if `LLM_API_KEY` is non-empty, otherwise `apiKey: 'user_provided'`, so each user enters their own key (supported with a fixed baseURL: `endpoints/custom/initialize.ts:194-221`);
2. adds an `mcpServers:` block with one entry for each enabled MCP:
   - `postgres`: if `PG_MCP_ENABLED=1`, `type: sse` and `url: '${PG_MCP_URL}'`. `PG_MCP_URL` is set in the api env to `http://srv-captain--$$cap_appname-pg-mcp:8000/sse`, so the script text holds no app-specific value;
   - `windmill`: if `WINDMILL_MCP_URL` is non-empty, `type: streamable-http` and `url: '${WINDMILL_MCP_URL}'`, plus `headers.Authorization: 'Bearer ${WINDMILL_MCP_TOKEN}'` when the token is set;
   - `superset`: same pattern with `SUPERSET_MCP_URL` / `SUPERSET_MCP_TOKEN`;
3. omits `mcpServers` entirely when no MCP is enabled;
4. validates at **every** start, not only at install, because env edits after install bypass the one-click regexes:
   - **pre-check:** before any file write, a `node -e` check runs on the **resolved env values**. It tests `LLM_NAME`, `LLM_DEFAULT_MODEL`, `PG_MCP_ENABLED`, `LLM_API_KEY`, `WINDMILL_MCP_TOKEN`, `SUPERSET_MCP_TOKEN` (empty allowed) and each URL against the §3.4 regexes, copied verbatim into one JS object. An empty optional URL (`WINDMILL_MCP_URL`, `SUPERSET_MCP_URL`) is skipped, not parsed. URL rules for `LLM_BASE_URL` (always set, has a default), and for each non-empty `WINDMILL_MCP_URL`/`SUPERSET_MCP_URL`: (a) `new URL()` must parse; (b) no userinfo; (c) no query parameter named `token`, `api_key`, `apikey` or `access_token` (case-insensitive); (d) scheme `https:`, or `http:` only when the hostname matches `^srv-captain--[a-z0-9-]+$`; (e) no `'"\` and no whitespace in the raw string. `PG_MCP_URL` is fixed and exempt. Any failure prints the variable name only (never its value) and exits 1;
   - **post-check:** after writing, it runs `node -e` with the image's bundled `librechat-data-provider`: it reads the file (`fs.readFileSync`), parses the contents with `js-yaml.load` and calls `configSchema.strict().safeParse` (exported at `packages/data-provider/src/config.ts:3841`, re-exported from `src/index.ts`). On failure it prints the zod issues and exits 1;
   - with `set -eu`, any failed step therefore exits non-zero **before** node starts, so a malformed or invalid config is never served. This also closes the "malformed YAML means silently no custom config" path;
5. runs `exec node server/index.js` (PID 1, signals pass through).

Canonical source: `scripts/librechat-boot.sh` in this repo. The template's array `command` text, and the decoded base64 in the fallback form, must each be byte-equal to it. §5.2 asserts both. Fallback form (D1 sub-variant, not a new decision): if spike 6.3a shows the array form is mangled, `command` becomes `sh -c 'echo <BASE64> | base64 -d | sh'`, where `<BASE64>` encodes that file. `$$cap_*` still appears only in `environment`.

Safety rules (regexes alone are not the defence):
- `$$cap_*` placeholders appear **only in `environment:` values**, never in the script text. The script is a fixed literal.
- The script reads user values only as quoted expansions (`"$VAR"`), writes them only through fixed `printf '%s'` formats, and never uses `eval` or `sh -c "$VAR"`.
- Secrets and URLs are written as literal `${VAR}` placeholders, produced from single-quoted shell strings so the shell does not expand them. LibreChat resolves them at runtime (`extractEnvVariable`; MCP `url`/`headers`: `packages/api/src/utils/env.ts:482-526`; headers are forwarded on streamable-http: `mcp/connection.ts:1950-1961`). The generated file holds no secret values.
- No `dockerfileLines`, so nothing gets baked into an image.
- Each MCP entry gets `initTimeout: 30000`. An individual MCP init failure is contained (`mcp/registry/MCPServersInitializer.ts:134-163`), and this is still covered by acceptance criteria (§5).
- Config schema-validation errors make LibreChat exit (`packages/api/src/app/loader.ts:282-314`). Malformed YAML is silently treated as "no custom config" (`:229-245`), which would hide the Tinfoil endpoint. So the test (§5) validates against LibreChat's schema, not only YAML syntax.
- The script is the single source of truth. A repo test extracts it from the template and runs it.

### 3.4 One-click variables

Required (auto-filled):

| id | default | validRegex |
|---|---|---|
| `$$cap_librechat_version` | `v0.8.8` | `/^v?[\w.-]{1,32}$/` |
| `$$cap_mongo_version` | `8.0.20` | `/^[\w.-]{1,32}$/` |
| `$$cap_creds_key` | `$$cap_gen_random_hex(64)` | `/^[0-9a-f]{64}$/` |
| `$$cap_creds_iv` | `$$cap_gen_random_hex(32)` | `/^[0-9a-f]{32}$/` |
| `$$cap_jw_secret`, `$$cap_jw_refresh_secret` | `$$cap_gen_random_hex(64)` | `/^[0-9a-f]{32,128}$/` |
| `$$cap_mongo_password` | `$$cap_gen_random_hex(32)` | `/^[0-9a-f]{32,64}$/` |
| `$$cap_allow_registration` | `true` | `/^(true\|false)$/` (instructions: set `false` after creating the admin) |

LLM endpoint (OpenAI-compatible, Tinfoil recommended):

| id | env | default | validRegex |
|---|---|---|---|
| `$$cap_llm_name` | `LLM_NAME` | `Tinfoil` | `/^[\w .-]{1,32}$/` |
| `$$cap_llm_base_url` | `LLM_BASE_URL` | `https://inference.tinfoil.sh/v1` | `/^https?:\/\/[^'"\\\s]+$/` |
| `$$cap_llm_api_key` | `LLM_API_KEY` | empty means `user_provided` | `/^[A-Za-z0-9_.~:-]{0,512}$/` |
| `$$cap_llm_default_model` | `LLM_DEFAULT_MODEL` | `gpt-oss-120b` (documented in the Tinfoil quickstart, so the safest default); `kimi-k3` is the alternative | `/^[\w.:\/-]{1,128}$/` |
| `$$cap_llm_models` | `LLM_MODELS` | `gpt-oss-120b,kimi-k3,glm-5-3,gemma4-31b,llama3-3-70b` (first entry is LibreChat's default; `LLM_DEFAULT_MODEL` is emitted first and deduped) | `/^[\w.:\/-]{1,128}([,][\w.:\/-]{1,128}){0,31}$/` |

No other provider variables. Admins can add more providers later by editing the env and config.

Security note: calling `inference.tinfoil.sh` directly gets TLS but no client-side enclave attestation (D6, accepted for v1). `LLM_BASE_URL` stays overridable for a future proxy. The `end` instructions say this.

Optional MCP variables (all empty by default):

| id | used for | validRegex (input hygiene only, not the injection defence: see §3.3) |
|---|---|---|
| `$$cap_pg_mcp_enabled` | api `PG_MCP_ENABLED`; default `0`. Set `1` together with the DSN below. | `/^[01]$/` |
| `$$cap_pg_mcp_database_uri` | pg-mcp `DATABASE_URI` (use a SELECT-only role) | `/^(postgres(ql)?:\/\/[^'"\\\s]+)?$/` |
| `$$cap_windmill_mcp_url` | e.g. `http://srv-captain--windmill:8000/api/mcp/w/librechat-agent/mcp` | `/^(https?:\/\/[^'"\\\s]+)?$/` |
| `$$cap_windmill_mcp_token` | Bearer token | `/^[A-Za-z0-9_.~-]{0,256}$/` |
| `$$cap_superset_mcp_url` | e.g. `http://srv-captain--superset-mcp:5008/mcp` | URL regex as above |
| `$$cap_superset_mcp_token` | Bearer JWT | `/^[A-Za-z0-9_.~=-]{0,4096}$/` |

The Superset URL example `http://srv-captain--superset-mcp:5008/mcp` is an example only; the real app name is the user's. v1 has one Superset entry per install; its role is set by that process's `MCP_DEV_USERNAME` (D10).

Cross-app references are plain URLs using `srv-captain--<other-app>`. They never go in `depends_on`.

### 3.5 Instructions

- `start`: what gets deployed; each MCP is optional; what to prepare before install (a Postgres read-only role, a dedicated Windmill workspace with a non-admin user and its MCP token (§4), the Superset MCP process); Mongo needs a CPU with AVX; the CapRover wildcard DNS must be set up, because HTTPS needs it.
- `end` (numbered, repo pattern from `rastro.yml`):
  1. On app `$$cap_appname`: enable HTTPS and Force HTTPS BEFORE the first login. LibreChat runs in production mode, so login cookies are sent only over HTTPS; over plain HTTP, login fails or loops. For a custom domain, enable HTTPS on it and set `DOMAIN_CLIENT` and `DOMAIN_SERVER` to `https://<your-domain>`.
  2. Then: the URL; create the first account, then set `ALLOW_REGISTRATION=false`; back up `CREDS_KEY`/`IV` and the Mongo password; how to set `DOMAIN_CLIENT`/`DOMAIN_SERVER` for a custom domain; the Tinfoil attestation note; what to check if an MCP is missing (api logs).
- MCP change procedure (one procedure, documented in `end`):
  - Windmill/Superset: edit the `*_MCP_URL`/`*_MCP_TOKEN` env on the api app, then save and restart. Clearing the URL removes the entry.
  - Postgres on: set `DATABASE_URI` on the `-pg-mcp` app and restart it, then set `PG_MCP_ENABLED=1` on the api app and restart it.
  - Postgres off: set `PG_MCP_ENABLED=0` on the api app, then clear `DATABASE_URI` on `-pg-mcp`. Both apps restart.

- Token expiry: the Superset token (HS256) carries `exp`, and Superset returns 401 when it expires. The Windmill token may also be revoked or expire. Docs tell users to set a long `exp` or rotate by editing `SUPERSET_MCP_TOKEN` / `WINDMILL_MCP_TOKEN` and restarting the api app. Long-lived token issuance verified by spike 6.4 (365 days accepted; `specs/librechat-superset.md`).

### 3.6 Operations (backup, upgrade, rollback)

- **Backup (v1, manual; Q7).** Before every upgrade, and on a schedule the admin chooses:
  1. `docker exec $(docker ps -qf name=^srv-captain--<app>-mongodb\.) mongodump -u librechat -p <password> --authenticationDatabase admin --archive --gzip > librechat-<date>.archive.gz`
  2. Tar the `$$cap_appname-uploads` and `$$cap_appname-images` volumes. Logs are not backed up.
  3. Store `CREDS_KEY`, `CREDS_IV`, `JWT_*` and the Mongo password with the backup. Without `CREDS_*`, restored user API keys are unreadable.
  - Restore (full): `docker exec -i $(docker ps -qf name=^srv-captain--<app>-mongodb\.) mongorestore -u librechat -p <password> --authenticationDatabase admin --archive --gzip --drop < librechat-<date>.archive.gz`, then restore the volume tars. `-p` on the command line is visible in `ps`; accepted for a manual admin procedure.
  - Rollback: always restore the pre-upgrade dump (do not guess whether migrations ran).
  - Scheduled backup sidecar: v2 (needs an off-server destination, retention and alerting).
- **Upgrade (LibreChat):** take a backup, then change the image tag in the CapRover app and redeploy. The one-click variables are install-only. The command override must survive the tag change (spike 6.3a).
- **Rollback:** redeploy the previous tag. If the new version ran migrations, restore the pre-upgrade dump.
- **Mongo:** v1 allows patch upgrades inside `8.0.x` only. Major upgrades need the featureCompatibilityVersion procedure and are out of scope.
- Consistency: stop the api (no writes) before `mongodump` and the volume tars, then start it. Restore runs before the selected image starts. "No data loss" means the pre-upgrade snapshot is intact and restorable.
- Acceptance (§5.9): backup, wipe, restore, login, an old conversation, and a stored user key that still works. §5.10: v0.8.8 → newer patch → rollback to v0.8.8 with restore, no data loss.

## 4. Security requirements

- `SESSION_COOKIE_SECURE` is NOT exposed as a variable. Secure cookies follow LibreChat's `shouldUseSecureCookie()` (`packages/api/src/oauth/csrf.ts:21-35`). Plain-HTTP login is not supported.

- Postgres MCP always runs with `--access-mode=restricted` and must not be exposed as a web app. Docs tell users to create a dedicated SELECT-only role.
- The Windmill and Superset tokens are passed only as env, read via `${VAR}`, and sent in headers, never in the query string. Windmill (D11, default): a dedicated workspace `librechat-agent` and a dedicated **non-admin** user `librechat-agent` that is writer in that workspace only. Spike 6.6: token creation accepts any scope string, so typos are not caught; the MCP endpoint takes `mcp:endpoints:<tools>` (the folder alternative also needs `mcp:scripts:<path>/*` and `mcp:flows:<path>/*`); API domain scopes such as `scripts:write:f/agent/*` get 403 there. Grant `scripts:write`/`flows:write` only if the agent must create things; otherwise use the Read-only toggle. Limit MCP tool exposure to `f/agent`. Never use an admin user: `deleteScriptByPath` and `deleteScriptByHash` are admin-only. Spike 6.6 found a gap: a schedule inside `f/agent` can run a script outside it. Per D11 the dedicated workspace is therefore the default; the folder setup is an alternative only with schedule tools removed.
- Superset identity (spike 6.4): the JWT `sub` does not select the user. `get_user_from_request()` (`auth.py:176`) prefers an already-set `g.user`, then `MCP_DEV_USERNAME`, then fails. A `default_user_resolver()` exists at `mcp_config.py:346` but is called by nothing in 6.1.0, and there is no `MCP_USER_RESOLVER` setting; both are 7.x additions. One process per `MCP_DEV_USERNAME` identity is therefore a property of our configuration, not an MCP-wide constraint.
- Ownership is the only object-level boundary in 6.1.0: there is **no** `raise_for_editorship` in the tag (zero occurrences; it arrives in 7.x). Every mutation path checks `raise_for_ownership` (`security/manager.py:3125`): MCP `update_chart` (`commands/chart/update.py:119`), MCP `add_chart_to_existing_dashboard` (`dashboard/tool/add_chart_to_existing_dashboard.py:340`), REST dashboard PUT (`commands/dashboard/update.py:94`), REST chart DELETE (`commands/chart/delete.py:68`), REST dataset DELETE (`commands/dataset/delete.py:55`). Admin bypasses it; we never grant Admin. The agent therefore may only mutate objects it owns, which is exactly the requirement.
- The agent account is a normal user plus a custom role: `can_read`+`can_write` on Dashboard, Chart and Dataset, `can_read` on Database, nothing on SQLLab / SavedQuery / User / Role / RLS, and **explicit** `datasource_access` per dataset (never `all_datasource_access`) plus `database_access` on each specific database (never the global `all_database_access`). Object-class permissions alone do not grant chart or data access; `can_access_datasource` / `can_access_database` are additionally checked inside tools (`auth.py:232`, `chart_utils.py:61`).
- `create_virtual_dataset` is SQL-bearing but bounded: `CreateDatasetCommand.validate()` calls `raise_for_access(database=..., sql=..., catalog=..., schema=...)` (`commands/dataset/create.py:88-96`), so the SQL runs only against databases granted to the role, and the created dataset is owned by the acting user. Granting Dataset `can_write` does not grant unrestricted SQL.
- REST deletes are HARD in 6.1.0 (no `SOFT_DELETE` / `SoftDeleteMixin` in the tag). Any helper must say so in its own output.
- The REST helper (`scripts/superset_dashboard_ctl.py`) must keep a cookie session and send `X-CSRFToken` (`WTF_CSRF_ENABLED=True`, CRUD not exempt), and must not expose generic URL/PUT/DELETE or arbitrary SQL — only the narrow semantic operations, each preflighting ownership while relying on Superset's command layer as the backstop.
- Pinned image tags everywhere, no `latest`.
- Env secrets (`CREDS_*`, `JWT_*`, Mongo password, MCP tokens, DSN, LLM key) are plain text in the CapRover app config and in `docker service inspect`. Anyone with CapRover admin or Docker socket access can read them. Accepted for v1.
- Tinfoil attestation (D6, accepted for v1): direct https gives TLS only, with no enclave attestation. The `end` instructions state this gap.
- Injection defence is structural (§3.3 safety rules): startup-script inputs only in env values (`$$cap_*` in `environment:`; image tags, service names and volume names are template fields, not script inputs), a fixed script, quoted expansions, no `eval`. Regexes are extra input hygiene, and they also stop raw `"`/`\`/newline from breaking CapRover's unescaped JSON substitution.
- **Trust boundary: the CapRover overlay network.** `notExposeAsWebApp` blocks ingress only; every app on the same CapRover can reach `srv-captain--*`. Hence Mongo runs **with auth**. The Postgres MCP SSE endpoint has no auth of its own, so any overlay peer could call its read-only tools. This is accepted and documented: it is acceptable only on a CapRover whose apps are all trusted, and the restricted mode plus a SELECT-only role limit the damage.
- Bearer tokens over `http://srv-captain--…` stay inside the overlay. Any external MCP or LLM URL must be `https://`; this is enforced at startup (§3.3 step 4d), not only documented.

## 5. Acceptance criteria

Execution target (2026-10-13 live results, test apps `librechat-test*` on production; Rastro/Superset/Windmill untouched per user): §5.3 PASS (boot, config, HTTPS login, first account; Tinfoil chat pending user key entry). §5.4 PASS (pg-mcp idles, `pg-mcp-disabled` in live logs). §5.11 PASS (HTTPS + Force HTTPS on; registration closes with 403 after ALLOW_REGISTRATION=false). §5.5/§5.8 SKIPPED this run (integrations untouched by decision). §5.9/§5.10 BLOCKED — no server shell exists (dashboard-only access; user decision 2026-10-13). The manual backup in docs/librechat-integrations.md §4 needs a host shell to run; documented for whoever gains one. Tinfoil chat verified by the user in the UI (gpt-oss-120b). §5.3 fully PASS. Install route identified: one CapRover app per service, command via `serviceUpdateOverride` (dashboard JS decoded); server also wants per-service memory limits (1.5 GB applied, documented). §5.2 runs in Docker: ALL CHECKS PASSED.

1. `npm run validate_apps` and `npm run formatter` pass, and the logo is present. Logo: `public/v4/logos/librechat.png`, converted from LibreChat's own logo asset (MIT licence, source recorded in §8). Test entry point: `npm run test_librechat` (needs docker; not part of `validate_apps`). Extraction uses node with the repo's `yaml@^1`, not yq. CI: a GitHub Actions job runs the test only when `public/v4/apps/librechat.yml`, `scripts/librechat-boot.sh`, `scripts/test_librechat_config.sh`, `scripts/superset_mint_mcp_token.py` or the workflow file itself changes (Q9).
2. Generator test (`npm run test_librechat` → `scripts/test_librechat_config.sh`): run the extracted `command` script **in the pinned librechat-api image**. Each case exports its full env before the run, because the schema may resolve `${VAR}` before checking `url` for these cases: none, pg only, windmill only, superset only, superset with an empty token, all, and LLM key set vs empty; windmill with an empty token; a token set with its URL empty (no entry). Each output must:
   - pass LibreChat's own config schema (`configSchema` from `librechat-data-provider`), not only YAML parsing;
   - contain exactly the expected `mcpServers` keys, plus a concrete endpoint `name` and model;
   - contain no secret value (grep for every token/key value).
   It also covers hostile values (`$(id)`, backticks, `;`, `&`) in URL and token variables: none of them executes, and none reaches the file unescaped. Payloads include `$(touch /tmp/pwned)`; the test asserts `/tmp/pwned` does not exist.
   A failing generator (unwritable path, an apostrophe or newline in `LLM_NAME`, `PG_MCP_ENABLED=2`) must exit non-zero without starting node. The test pre-seeds `/app/librechat.yaml` with a sentinel and asserts it is byte-identical after each failing case. The test validator is the same `configSchema.strict().safeParse` the startup post-check uses.
2b. Input-pattern test: the §3.4 `validRegex` strings and the regexes in the startup script's pre-check are extracted by the test and asserted identical.
3. Live install on a test CapRover with all MCP variables empty: login works, there are no MCP errors in the logs, and a chat works through Tinfoil, both with the admin key and with the `user_provided` key.
4. Exact-image smoke: the pinned librechat-api image boots with the generated config. The pinned postgres-mcp image idles with an empty DSN and serves `/sse` on `0.0.0.0:8000` with a DSN.
5. Live install with pg + windmill filled in: both servers show as connected in the LibreChat MCP panel.
   - Postgres: a read query works; a write statement fails in `restricted` mode.
   - Windmill (D11): the dedicated workspace is tested, not assumed. Token = the workspace token from §4 on a fresh install. `createScript`, `runScriptByPath` and `createSchedule` (6-field cron) succeed inside `librechat-agent`; against another workspace's MCP endpoint (`/api/mcp/w/<other>/mcp`) with the same token, `listScripts` and `getScriptByPath` fail or return only that token's own workspace, never the other workspace's scripts. If the folder alternative is used instead, a schedule inside `f/agent` pointing at a script outside it must be rejected (accepted in spike 6.6). Scripts created via API need their lock before run-by-path; the test polls. Then `createScript`, `runScriptByPath` and `createSchedule` (6-field cron incl. seconds) work in a test workspace, and `getJobLogs` returns logs for debugging. With a non-admin token, `deleteScriptByPath` is rejected.
6. Failure and recovery: point one MCP at an unreachable URL. Login and normal chat still work, and the logs name the failing server. Fixing the env and restarting restores it. The §3.5 on/off procedure works in both directions for Postgres.
7. Redeploy or restart keeps users, conversations, uploaded files and stored credentials (fixed `CREDS_*`, Mongo volume).
8. Superset (release blocker, primary integration): with `superset_mcp_url` and token filled in, Superset shows as connected.
   - Read: `list_dashboards`, `get_dashboard_info`, `list_charts`, `get_chart_data` and `list_datasets` return data. (`get_dashboard_data` is a 7.x tool and does not exist on 6.1.0.)
   - Write: `generate_dashboard` succeeds in a test workspace through the `alpha` process, and is rejected through the read-only process (its custom role has no `can_write` on Dashboard or Chart).
   - `execute_sql` is allowed only for the chosen identity, via RBAC alone: on 6.1.0 no default non-admin role holds `can_execute_sql_query` on SQLLab, and there is no tool allow/deny list to remove it. The dedicated agent account must not be granted that permission.
   - `instructions.start` (prerequisites) and `instructions.end` (setup steps) cover the Superset-side setup, with a link to the spike 6.4 output `specs/librechat-superset.md`. `description` stays ≤200 chars (enforced by `validate_apps.js`). The setup text covers the pinned install `apache-superset[fastmcp]==6.1.0` plus `flask-caching==2.3.0` and `fastmcp==3.1.0` (both required, §2), `superset mcp run`, JWT config, token issuing and expiry. Superset 6.1.0 uses one fixed user per process (spike 6.4), so the Alpha and read-only checks run against two MCP processes, each with its own `MCP_DEV_USERNAME`, URL and token. A token minted by `scripts/superset_mint_mcp_token.py --days 365` is accepted; an expired token gets 401, and LibreChat logs the server as failed while chat keeps working.

9. Backup and restore (§3.6): follow §3.6 exactly (api scaled to 0, dump, both volume tars, secrets record; the Mongo lookup must print exactly one container ID), restore into a fresh install, then check login, an old conversation, an uploaded file, and a stored user API key.
10. Upgrade and rollback (§3.6): v0.8.8 → newer patch → rollback to v0.8.8 with a restore, no data loss, and the command override intact after each tag change. Pass = the §5.9 checks succeed after rollback.
11. Login over HTTPS works. Login over plain HTTP fails (expected; D7).
12. Hostile inputs (§3.3 step 4): `https://u:p@h/x`, `https://h/mcp?token=abc`, `http://example.com/mcp` each fail before any file is written. `http://srv-captain--windmill:8000/…` passes. A newline or space in `WINDMILL_MCP_TOKEN` fails the pre-check before any file is written.

## 6. Open questions / spikes (resolved in PLAN, before template code)

1. LibreChat image. RESOLVED: `docker.io/librechat/librechat-api:v0.8.8`, anonymous pull (Docker Hub); GHCR fallback; WORKDIR/CMD/config path/`configSchema` export (sources in §2). RESOLVED by local spike (2026-10-09, `specs/spike-images.md`): `librechat-data-provider` `configSchema` and `js-yaml` load from `/app/api`; a minimal config passes `configSchema.safeParse`; an invalid MCP `type` fails it; `/app/librechat.yaml` is absent and writable (image runs as root, uid 0). Scripts outside `/app` need `NODE_PATH=/app/node_modules:/app/api/node_modules`. Server boot not tested (needs Mongo). Mongo: `mongo:8.0.20` exists on Docker Hub (anonymous pull, updated 2026-04-16); latest 8.0.x patch still to confirm.
2. Postgres MCP. RESOLVED: flags `--access-mode=restricted|unrestricted`, `--transport=sse`, `DATABASE_URI`, SSE port 8000. RESOLVED by local spike (2026-10-09): tag `0.3.0`; entrypoint `/app/docker-entrypoint.sh postgres-mcp`; `/bin/sh`, `tail`, `sleep`, `base64` present; the entrypoint adds `--sse-host=0.0.0.0` only when it runs; empty DSN exits 1; the wrapper above idles; `GET /sse` returned 200 with a DSN. OPEN: default access mode (`--help` does not show it; pass it explicitly). Real CapRover delivery of the wrapper is still spike 6.3. Decision rule: if the pinned image has `/bin/sh`, the service uses `command: ['sh','-c', 'if [ -z "${DATABASE_URI:-}" ]; then echo "pg-mcp disabled"; exec tail -f /dev/null; fi; exec <entry> --access-mode=restricted --transport=sse …']`. If it has no shell, Postgres MCP moves to v2 (no PyPI install at boot). Gates: pg-mcp service, §5.4, §5.5.
3. RESOLVED. Per-image ENTRYPOINT and CMD are recorded in `specs/spike-images.md` (6.1, 6.2). Which Swarm field CapRover writes: proven by the production test (6.3a) — the array ran as `sh -c` (not as arguments to the image entrypoint), so CapRover writes `Command`, which replaces ENTRYPOINT+CMD; this is why the boot script ends with `exec node server/index.js` and the pg-mcp wrapper passes `--sse-host` itself. `base64` and `tail` exist in both images.
3a. RESOLVED (2026-10-12: throwaway app `spike-test` on production CapRover logs `SPIKE 0=MARK 1=a b 2= env=hello` and `SPIKE_TAG_CHECK`, so the array `command` reached the container intact; the dashboard install returned HTTP 500 after version 1 was created, image name not recorded; tag-change test PASS: after redeploy with image `alpine:3.19` (deployedVersion 1, read-only API check), the same SPIKE line appeared with the same arguments and env). Route: CapRover dashboard only (no SSH). Proof: the throwaway app's logs show the argv it received (`$0` and `$@`), and the same after a tag change in the dashboard. CapRover `command` as a YAML array with a multi-line script containing `${…}` and `$VAR`: test on a real server that it reaches Swarm unmodified, and that the override survives a later image-tag change in the CapRover UI. If mangled, use the base64 fallback (§3.3). Gates: §3.3, §5.2, D1.
4. Superset MCP. RESOLVED: first release with MCP is 6.1.0 (PyPI 2026-05-13); fastmcp extra; streamable HTTP at `/mcp`; HS256 + `exp` rules; `MCP_REQUIRED_SCOPES`; RBAC and tools (sources in §2). RESOLVED (spike 6.4, local; evidence `specs/librechat-superset.md`): `sub` is ignored; identity is fixed per process by `MCP_DEV_USERNAME`, so each role needs its own process. Pins: `flask-caching==2.3.0`, `fastmcp==3.1.0`. The Gamma claim in earlier drafts was wrong: Gamma can write Dashboards and Charts in 6.1.0. BUILD task T96 (tsk board): token minting script `scripts/superset_mint_mcp_token.py` (Python stdlib only, reads `MCP_JWT_SECRET` from env, never prints it; args `--sub --iss --aud --scopes --days`); claims: `scope` string (not `scopes`); 1-year `exp` and expired-token 401 verified. BUILD task T97 output: the setup docs cover how the user's Superset image gets the fastmcp extra and runs `superset mcp run` (pinned install above). Gates: §5.8, `instructions`.
5. RESOLVED (docs + source; live check stays in §5.5). Windmill accepts `Authorization: Bearer`. LibreChat forwards YAML `headers` on streamable-http (`mcp/connection.ts:1950-1961`).
6. Windmill. RESOLVED: minimum version v1.484.0; token scopes and path restriction documented (§2). RESOLVED (spike 6.6, Windmill CE 1.830.0, `specs/spike-windmill.md`): API domains are `schedules:write[path]`, `jobs:run:scripts[path]`, `jobs:run:flows[path]`; `jobs:run` is invalid. The MCP endpoint needs `mcp:*` scopes. Folder gap: schedules escape `f/agent`. Gate for the D11 default: verify the dedicated-workspace token and its endpoint scopes on a live install (§5.5). Spike: on the test Windmill, create a token with each scope ticked and read its scope list; write the real strings into §4. Gates: §4 and §5.5.
7. Tinfoil. RESOLVED: base URL confirmed; model IDs listed; default model `gpt-oss-120b`; `fetch: false` (§3.3). RESOLVED for v1 (spike 6.7): title calls work with enough output tokens; `titleConvo` stays `false` until LibreChat's title budget is checked. Attestation is not checked in v1 (D6).


## 7. Decisions (resolved 2026-10-09)


- D1. Config is generated by an inline `sh -c` script in the api service `command` (array form). No wrapper image.
- D2. Subject to D9: Postgres MCP runs as its own always-deployed service and idles when `DATABASE_URI` is empty.
- D3. Labels and instructions are in English.
- D4. Superset is in v1. It is the main integration and a release blocker (§5.8), not experimental.
- D5. A single OpenAI-compatible endpoint, Tinfoil recommended, with variables for URL, API key, display name and default model (§3.4).
- D6. DECIDED 2026-10-09: option (a), direct HTTPS to `https://inference.tinfoil.sh/v1`. No attestation. Accepted risk: LibreChat cannot prove that chat data is processed in an enclave, and a man-in-the-middle is not detected beyond TLS. The `end` instructions must say so. `LLM_BASE_URL` stays overridable, so a future proxy or SDK setup needs no template change.
  - Rejected for v1: (b) Tinfoil Proxy sidecar (`ghcr.io/tinfoilsh/tinfoil-proxy`, docs https://docs.tinfoil.sh/local-proxy/cli.md). Revisit in v2 if the trust model changes.
  - Rejected for v1: (c) Tinfoil SDK in a custom image.
- D7. Plain-HTTP login is not supported. HTTPS is enabled in CapRover before the first login, following the Rastro pattern (Q8).
- D8. Base64 fallback for the startup command is a sub-variant of D1, not a new decision (Q2).
- D9. Postgres MCP ships in v1 only if the pinned image has a shell (and ENTRYPOINT is compatible, spike 6.3). Otherwise it moves to v2, which drops: `$$cap_pg_mcp_*`, `PG_MCP_*`, the pg-mcp service, §3.5 on/off, §5.4 and §5.5 Postgres checks, §5.6 Postgres. No PyPI install at boot (Q3).
- D10. Superset identity (spike 6.4): `sub` is ignored; one MCP process per role, each fixed by `MCP_DEV_USERNAME` (Q4). v1 ships one Superset entry per install, whose role the admin picks; a second role is v2. Token minting script lives in this repo at `scripts/superset_mint_mcp_token.py` (Q5).
- D11. Windmill: DEFAULT is a dedicated workspace for the agent with a non-admin user (spike 6.6: a folder-scoped token's schedule can run a script outside the folder). Folder-scoped MCP tokens (`mcp:scripts:f/agent/*`, `mcp:flows:f/agent/*`) are the documented alternative, and only with schedule tools removed from the endpoint (Q6).
- D12. Backups for v1 are manual (`mongodump` plus volume tars, §3.6). Scheduled backups are v2 (Q7).
- D13. `test_librechat` runs locally and in a GitHub Actions job on relevant path changes (Q9).


## 8. Sources

Research notes from 4 Haiku subagents (2026-10-09). The scratch files were lost on a session restart; the relevant facts are reproduced in §2 with source paths. LibreChat source is checked at `LibreChat-AI/LibreChat` e1dfc10.
- LibreChat MCP docs: https://www.librechat.ai/docs/configuration/librechat_yaml/object_structure/mcp_servers
- Windmill MCP: https://www.windmill.dev/docs/core_concepts/mcp
- Postgres MCP Pro: https://github.com/crystaldba/postgres-mcp
- Superset MCP server docs ("Next"): https://superset.apache.org/admin-docs/configuration/mcp-server/
- Superset 6.1 release (Preset): https://preset.io/blog/apache-superset-6-1-release/
- Tinfoil Python SDK (attestation): https://docs.tinfoil.sh/sdk/python-sdk
- Tinfoil direct API access: https://docs.tinfoil.sh/sdk/direct-api-access
- Tinfoil coding-agents tutorial (no attestation with plain clients): https://docs.tinfoil.sh/tutorials/coding-agents
- LibreChat image on Docker Hub: https://hub.docker.com/r/librechat/librechat-api
- LibreChat Dockerfile.multi @ v0.8.8: https://github.com/LibreChat-AI/LibreChat/blob/v0.8.8/Dockerfile.multi
- Superset 6.1.0 MCP CLI: https://github.com/apache/superset/blob/6.1.0/superset/cli/mcp.py
- Windmill v1.484.0 release: https://github.com/windmill-labs/windmill/releases/tag/v1.484.0
- Windmill user tokens: https://www.windmill.dev/docs/core_concepts/user_tokens
- Windmill OpenAPI (NewSchedule): https://raw.githubusercontent.com/windmill-labs/windmill/main/backend/windmill-api/openapi.yaml
- Tinfoil base URL: https://inference.tinfoil.sh/v1
- Superset source README (fastmcp extra): `apache/superset` repo
- LibreChat `tag-images.yml` and compose files: `LibreChat-AI/LibreChat`
- Logo: LibreChat `client/public/assets/logo.svg` (MIT), converted to PNG for `public/v4/logos/librechat.png`
- CapRover one-click format: this repo's `README.md`; upstream `caprover/one-click-apps` `lemmy.yml`
