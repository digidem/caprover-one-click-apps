# LibreChat one-click app — integrations guide

Setup for the optional MCP integrations of
[`public/v4/apps/librechat.yml`](../public/v4/apps/librechat.yml):
Postgres (read-only), Windmill (dedicated workspace), Superset (pinned exactly
6.1.0; one process per identity). Commands were tested as written; see
`specs/spike-*.md` in the repo for the evidence.

Every Superset claim below was verified against the `6.1.0` source tag, not the
"Next" documentation, which describes 7.x.

## 1. Superset MCP (primary integration)

Superset 6.1.0 exactly. Install pins (both required — the MCP server does not
work without them):

```bash
uv pip install "apache-superset[fastmcp]==6.1.0" "flask-caching==2.3.0" "fastmcp==3.1.0" PyJWT
```

Config (superset_config.py) block:

```python
MCP_AUTH_ENABLED = True
MCP_JWT_ALGORITHM = "HS256"
MCP_JWT_SECRET = os.environ["MCP_JWT_SECRET"]
MCP_DEV_USERNAME = "svc-chat-mcp"      # the Superset user whose permissions apply
MCP_REQUIRED_SCOPES = "mcp:read"
MCP_JWT_ISSUER = "superset"
MCP_JWT_AUDIENCE = "superset"
MCP_RBAC_ENABLED = True
```

The token `sub` does NOT select the Superset user in our configuration. In
`superset/mcp_service/auth.py:176` `get_user_from_request()` resolves, in order:
an already-populated `g.user`, then `MCP_DEV_USERNAME`, then it fails. A
`default_user_resolver()` function does exist at
`superset/mcp_service/mcp_config.py:346`, but **no code path in 6.1.0 calls
it** — it is dead code in this tag, and there is no `MCP_USER_RESOLVER` setting
either. So one process = one identity. This is a property of **our
configuration** (one `MCP_DEV_USERNAME` per process), not a law of MCP.

### No tool allow/deny list exists in 6.1.0

There is **no** config to enable or disable individual MCP tools in 6.1.0 — no
`MCP_DISABLED_TOOLS`, no equivalent. (It appears in `mcp_config.py` from the
7.0.0rc1 tag; on 6.1.0 the setting is simply read by nothing.) The tool surface
is fixed at **24 tools** and the only control over what the agent can do is the
FAB role of `MCP_DEV_USERNAME`.

Mint a token (any scope string is accepted by the JWT layer; scopes do not gate
individual tools — see below):

```bash
MCP_JWT_SECRET=... python3 scripts/superset_mint_mcp_token.py --sub svc-chat-mcp --scopes 'mcp:read' --days 30
--days 30 (short-lived) or --days 365 (spike 6.4: accepted)
```

`MCP_REQUIRED_SCOPES` is a **global JWT admission requirement only**
(`mcp_config.py:312` passes it to the verifier). 6.1.0 has **no per-tool scope
enforcement**: there is no `_token_scope_allows`, no
`superset:<resource>:<action>` scope map (both are 7.0). Therefore **`mcp:read`
alone does NOT make the agent read-only** — a token that satisfies the required
scope still runs any write tool the Superset user has permissions for. Treat
`mcp:read`/`mcp:write` as labels, not authorization tiers. The meaningful
controls are FAB RBAC + datasource/database access + object ownership.

### 1.1 Ownership is the real boundary (6.1.0)

**There is no `raise_for_editorship` in 6.1.0** — verified: zero occurrences in
the whole `superset/` package at tag `6.1.0`. 6.1.0 checks **ownership only**
(`raise_for_ownership`, `security/manager.py:3125`): the caller must be in the
object's `owners`, or be an Admin.

Every mutation path we depend on enforces it:

| Path | Check |
|---|---|
| MCP `add_chart_to_existing_dashboard` | `raise_for_ownership(dashboard)` — `dashboard/tool/add_chart_to_existing_dashboard.py:340`; production also patches in `raise_for_ownership(chart)` (see §1.8) |
| MCP `update_chart` | `UpdateChartCommand` → `raise_for_ownership` — `commands/chart/update.py:119` |
| MCP `generate_dashboard` / `generate_chart` | creates; owner defaults to the acting user (`commands/base.py:48`) |
| MCP `create_virtual_dataset` | `CreateDatasetCommand` → `raise_for_access(database, sql, catalog, schema)` — `commands/dataset/create.py:90` |
| REST `PUT /api/v1/dashboard/<pk>` | `UpdateDashboardCommand` → `raise_for_ownership` — `commands/dashboard/update.py:94` |
| REST `DELETE /api/v1/chart/<pk>` | `raise_for_ownership` — `commands/chart/delete.py:68` |
| REST `DELETE /api/v1/dataset/<pk>` | `raise_for_ownership` — `commands/dataset/delete.py:55` |

So the constraint "the agent may only alter what it owns, never other users'
objects" is enforced **by Superset itself**, identically over MCP and REST. Our
helper must not bypass it (and cannot: only Admin passes, and we never grant it).
The only case where a non-admin is refused is a pre-existing object owned by
someone else — which is intended behaviour, and is why the legacy orphan datasets
14-18 need a one-time Admin ownership assignment or Admin cleanup.

### 1.2 Agent role

The role below is written as the generic `MCP_DashboardAgent`; in production the
account is `svc-chat-mcp` with role `chat-mcp`, and both names work identically.
A custom role is required. Default Gamma can write Dashboards/Charts but not
Datasets; default Alpha has broad data-source rights. Neither default non-admin
role holds `can_execute_sql_query` on SQLLab.

Object-class permissions alone are **not** enough for chart and data access —
Superset additionally gates on `datasource_access` (per-dataset grants) and
database access. Both must be granted explicitly. The per-database grant is the
permission `database_access` on `database.perm`; `all_database_access` is a
single global pair and is NOT per-database (see the table).

| Class | Permissions | Why |
|---|---|---|
| `Dashboard` | `can_read`, `can_write` | create and edit dashboards |
| `Chart` | `can_read`, `can_write` | create and edit charts |
| `Dataset` | `can_read`, `can_write` | `create_virtual_dataset` needs `can_write` (Gamma is denied); creating datasets is an explicit requirement, so this stays |
| `Database` | `can_read` | `list_databases` / `get_database_info` |
| `SecurityRestApi` | `can_read` | required by the CSRF endpoint the REST helper calls (`GET /api/v1/security/csrf_token/` is `@protect()`-ed with `permission_name("read")`) |
| `SavedQuery` | none | no `save_sql_query` |
| `SQLLab` | none | `execute_sql` denied |
| `User`, `Role`, `Row Level Security`, `Manage` | none | never |
| `all_datasource_access` | **none** | do NOT grant; use explicit `datasource_access` per dataset |
| `database_access` on `<db>.perm` | per-database | grant on the specific databases the agent may use. **NEVER** `all_database_access` — that permission is a global pair `("all_database_access","all_database_access")` and grants every database |

Do **not** make this user an Admin: Admin passes every `raise_for_ownership`
check, which removes the ownership boundary above.

### 1.3 What `create_virtual_dataset` may and may not do

It is SQL-bearing, but it is **not arbitrary SQL over every datasource**.
`CreateDatasetCommand.validate()` (`commands/dataset/create.py:88-96`) calls
`security_manager.raise_for_access(database=..., sql=..., catalog=..., schema=...)`,
which fails when the database is not accessible to the caller
(`can_access_database`). The created dataset's owner is
the acting user, so it is deletable by them and by nobody else without Admin.

The practical boundary: **the agent can run SQL only against databases granted to
its role, and the results become its own dataset.** Grant `database_access`
only on the databases meant for the agent.

### 1.4 The 24 native MCP tools in 6.1.0

Chart: `list_charts`, `get_chart_info`, `get_chart_data`, `get_chart_preview`,
`generate_chart`, `update_chart`, `update_chart_preview`, `get_chart_type_schema`.
Dashboard: `list_dashboards`, `get_dashboard_info`, `generate_dashboard`,
`add_chart_to_existing_dashboard`. Dataset: `list_datasets`, `get_dataset_info`,
`create_virtual_dataset`. Database: `list_databases`, `get_database_info`.
SQL Lab: `execute_sql`, `open_sql_lab_with_context`, `save_sql_query`.
Explore: `generate_explore_link`. System: `health_check`, `get_instance_info`,
`get_schema`. (Verified against the `@tool` registrations at tag `6.1.0`.)

**Not in 6.1.0** (they are 7.0): `get_dashboard_data`, `manage_native_filters`,
`remove_chart_from_dashboard`, `delete_chart`, `delete_dashboard`,
`update_dashboard`, `update_dataset`, `query_dataset`, `list_metrics`,
`get_table`, `get_catalog`.

`add_chart_to_existing_dashboard` is the only dashboard-layout tool that
exists. It **can** place a chart into a dashboard — and, if you pass
`target_tab`, into an **existing** tab (matched by display name or ID,
`dashboard/tool/add_chart_to_existing_dashboard.py:441`). It **cannot** create a
tab, cannot move or reorder an existing component, and cannot remove one. It
writes `position_json` and `slices` together through `UpdateDashboardCommand`.

### 1.5 What the MCP in 6.1.0 cannot do

These actions have no 6.1.0 MCP tool and need the semantic REST helper:

rename/describe dashboards, charts and datasets, edit `position_json` (create a
tab, reorder, remove a chart), set native filters, delete a chart or a dataset.
The full set arrives in 7.0 (`update_dashboard`, `remove_chart_from_dashboard`,
`manage_native_filters`, `delete_chart`, `delete_dashboard`, `update_dataset`,
`query_dataset`).

**Chart delete in 6.1.0 is a HARD delete.** There is no `SOFT_DELETE` and no
`SoftDeleteMixin` anywhere in the 6.1.0 source (verified: zero occurrences in the
whole package). Deleted charts are gone; trash/restore is a later feature.

### 1.6 Tool discovery and RBAC

`MCP_TOOL_SEARCH_CONFIG` is enabled by default in 6.1.0 (`mcp_config.py:277`):
`strategy="bm25"`, `max_results=5`, `include_schemas=False`,
`always_visible=["health_check", "get_instance_info"]`. So a client sees
`health_check`, `get_instance_info`, `search_tools` and `call_tool` and
discovers the rest on demand.

6.1.0 does **not** permission-filter search or listing. `RBACToolVisibilityMiddleware`
and `is_tool_visible_to_current_user` are 7.0. Consequence: **a tool visible in
search results is not an authorized tool** — permission is checked at call time
and the call then fails with 403. Do not treat discoverability as capability.

### 1.7 Tool search / catalog config (unchanged behaviour)

No configuration change is needed to keep the narrow discovery surface: the
defaults above already do it. If you want a different `max_results` or to pin
extra always-visible tools, set `MCP_TOOL_SEARCH_CONFIG` in `superset_config.py`.
Note that `MCP_TOOL_SEARCH_CONFIG["enabled"] = False` already exposes the full
24-tool catalog in 6.1.0 (it does not select a different listing mode); the
native-listing and compact-listing knobs are a `master` addition.

### 1.8 Permission model per tool (RBAC matrix)

Each tool declares `class_permission_name` and a `method_permission_name` that
defaults to `write` when `tags` contains `"mutate"`, otherwise `read`
(`superset/core/mcp/core_mcp_injection.py`). The check runs in `mcp_auth_hook`
before the tool body. Exact matrix for 6.1.0:

| Tool | Class permission | Method permission |
|---|---|---|
| `list_charts` | `can_read` on Chart | read |
| `get_chart_info` | `can_read` on Chart | read |
| `get_chart_data` | `can_read` on Chart | read |
| `get_chart_preview` | `can_read` on Chart | read |
| `generate_chart` | `can_write` on Chart | write |
| `update_chart` | `can_write` on Chart | write |
| `update_chart_preview` | `can_write` on Chart | write |
| `get_chart_type_schema` | none declared | read |
| `list_dashboards` | `can_read` on Dashboard | read |
| `get_dashboard_info` | `can_read` on Dashboard | read |
| `generate_dashboard` | `can_write` on Dashboard | write |
| `add_chart_to_existing_dashboard` | `can_write` on Dashboard | write |
| `list_datasets` | `can_read` on Dataset | read |
| `get_dataset_info` | `can_read` on Dataset | read |
| `create_virtual_dataset` | `can_write` on Dataset | write |
| `list_databases` | `can_read` on Database | read |
| `get_database_info` | `can_read` on Database | read |
| `execute_sql` | `can_execute_sql_query` on SQLLab | execute_sql_query |
| `open_sql_lab_with_context` | `can_read` on SQLLab | read |
| `save_sql_query` | `can_write` on SavedQuery | write |
| `generate_explore_link` | `can_read` on Explore | read |
| `health_check` | none | none |
| `get_instance_info` | none | none |
| `get_schema` | none | none |

Class-level RBAC is **not** the whole check. `generate_chart` also calls
`has_dataset_access(dataset)` → `can_access_datasource`
(`chart/tool/generate_chart.py:316`), and the dashboard/dataset tools call
`check_chart_data_access(chart)` → `can_access_datasource`
(`mcp_service/auth.py:265`). `execute_sql` and `save_sql_query` additionally
call `can_access_database`. So `get_chart_data` needs Chart read **and**
datasource access; `execute_sql` needs SQLLab execute **and** database access.

In production, `add_chart_to_existing_dashboard` also requires **chart
ownership**: the deployed image patches the tool to run
`raise_for_ownership(chart)` before `check_chart_data_access`, so a chart the
acting user does not own is refused ("not owned by the service user") even when
its dataset is accessible. Verified live 2026-10-16.

### 1.9 Concurrency: no sequential-call requirement

A prior note claimed MCP calls must be issued sequentially because of
`DetachedInstanceError`. That is **not** a 6.1.0 constraint: `mcp_auth_hook`
pushes a fresh Flask app context per call, clears stale `g.user`, and rolls back
the session on error (`auth.py:390`, `auth.py:283`, `auth.py:357`). Nothing in the
tag requires or documents sequential execution. Do not carry that restriction
into LibreChat configuration.

### 1.10 Run as a service

Start `superset mcp run --host 0.0.0.0` and document `MCP_DEV_USERNAME` per
process. Superset 6.1.0 ships no systemd unit; document a container or systemd
unit per role process on the Superset host.
MCP endpoint: `https://<superset-host>/mcp` — the port is whatever `--port`
selected, and `5008` is only the conventional one.

**Healthcheck trap (verified against the 6.1.0 image family).** The official
image ships `/app/docker/docker-healthcheck.sh`, which runs
`curl -f "http://localhost:${SUPERSET_PORT}/health"`. If you override the
container command to `superset mcp run --port 5008`, nothing answers `/health`
on 5008, so the check fails and Docker kills and restarts the task roughly every
100 seconds — which looks like a crash loop or a flaky MCP, not a healthcheck.
Set `Healthcheck: NONE` in the service override for an MCP-only process.

### 1.11 REST helper for the actions MCP 6.1.0 cannot reach

`scripts/superset_dashboard_ctl.py` logs in as the agent account and performs the
semantic operations listed in 1.5. Stdlib only; credentials come from env and are
never printed. It captures the session cookie by hand and fetches a CSRF token
before every mutating call (see 1.11.1 for the two ordering rules that make this
work). It reports who owns an object, but never uses that as an authorisation
decision: Superset's `raise_for_ownership` is the authority, and the REST GET
serializers do not expose usernames (only ids, names and emails), so a username
comparison could not be made reliably anyway.

```bash
export SUPERSET_URL=https://superset.example.com
export SUPERSET_USERNAME=svc-chat-mcp
export SUPERSET_PASSWORD=<the agent account password>

# inspect before editing (shows owners, position_json, native filters)
python3 scripts/superset_dashboard_ctl.py show dashboard 5

# rename a dashboard (title/slug only - see the description note below)
python3 scripts/superset_dashboard_ctl.py rename-dashboard 5 --title "Frota"

# describe orphan datasets (dataset descriptions ARE supported over REST)
python3 scripts/superset_dashboard_ctl.py rename-dataset 17 --description "Dataset órfão, mantido para auditoria."

# create the "Distâncias" tab and place a chart into it (semantic, not raw JSON)
python3 scripts/superset_dashboard_ctl.py create-tab 6 --name "Distâncias" --charts 42
python3 scripts/superset_dashboard_ctl.py move-chart 6 42 --tab "Distâncias"

# replace a dashboard's native filters from a JSON array file
python3 scripts/superset_dashboard_ctl.py set-filters 6 filters.json

# detach chart 13 from dashboard 5 WITHOUT deleting the chart
python3 scripts/superset_dashboard_ctl.py remove-chart 5 13

# delete a chart or dataset the agent owns (permanent)
python3 scripts/superset_dashboard_ctl.py delete-chart 18
python3 scripts/superset_dashboard_ctl.py delete-dataset 18
```

Two operations do not exist over 6.1.0 REST and are refused with an explanation
instead of a server 400:

- **dashboard description.** `DashboardPutSchema` has no `description` field, so
  `rename-dashboard --description` is rejected. Set it in the Superset UI
  (dashboard -> Edit -> Properties) or by an Admin. Dataset and chart
  descriptions are supported.
- **moving a chart to the top level of an already tabbed dashboard.** ROOT may
  hold exactly one child, a GRID or a TABS. Use `--tab` on a tabbed dashboard.

A dashboard is a GRID *or* a TABS at top level. `create-tab` converts an
existing grid into a tab, carrying its charts over, so nothing is orphaned.

Exit codes: 0 ok, 1 refused or failed. A 403 normally means the object is not
owned by the agent, but Flask-AppBuilder can also return 403 for a missing
permission, so read the error text. A 404 means the id is wrong. `remove-chart` is
the operation REST cannot do safely on its own — see 1.11.1.

#### 1.11.1 CSRF, and why `remove-chart` is special

**CSRF is on.** `WTF_CSRF_ENABLED = True` (`config.py:305`) and
`BaseSupersetApiMixin.csrf_exempt = False` (`views/base_api.py:194`); the
`/api/v1/{dashboard,chart,dataset}` CRUD endpoints are **not** in
`WTF_CSRF_EXEMPT_LIST`. The helper therefore logs in, fetches
`GET /api/v1/security/csrf_token/`, and sends the token as the `X-CSRFToken`
header on every mutating call. Flask-WTF accepts the header when no form token is
present, and the helper also sends a same-origin `Referer` because
`WTF_CSRF_SSL_STRICT` defaults to True (mutations fail over HTTPS without it).
The CSRF endpoint is permission-protected, so the agent role needs `can_read` on
`SecurityRestApi`.

Two ordering rules were found by running this against a real 6.1.0 instance and
are easy to get wrong:

1. **The CSRF token and the session cookie must travel together, and the token
   must be fetched before the `Cookie` header is built.** The response to
   `/csrf_token/` re-issues the session cookie, and the token is only valid
   against the cookie it was minted for. Fetching the token *after* the cookie
   header is assembled sends the previous cookie, and Superset answers
   `400 The CSRF session token is missing`.
2. **Do not rely on an HTTP cookie jar.** Superset marks the session cookie
   `Secure` (observed on a real instance), so `http.cookiejar` will not replay it
   over plain `http://` — which is exactly how a local or CapRover-overlay
   Superset is reached. A jar that does hold cookies also emits its own `Cookie`
   header, which races the explicit one. The helper captures the raw
   `Set-Cookie` value and replays it by hand instead.

**Position-only surgery does not detach a chart.** `BaseDAO.update` is a plain
`setattr` (`daos/base.py:407`), so `PUT /dashboard/<pk>` with only `position_json`
edits the layout blob and leaves the `dashboard_slices` M2M rows untouched
(`models/dashboard.py:93` — `Slice`, `secondary=dashboard_slices`). The chart
would vanish from the layout but stay attached.

The one stock REST path that synchronizes both is `json_metadata.positions`:
`DashboardDAO.set_dash_metadata` (`daos/dashboard.py:246`) rebuilds
`dashboard.slices` from the `chartId`s found in `positions` **and** rewrites
`position_json` from the same data, inside the update transaction. `positions` is
a declared field of `DashboardJSONMetadataSchema` (`dashboards/schemas.py`), so it
passes validation (marshmallow 3 rejects unknown keys elsewhere).
`remove-chart` uses exactly that: it reads the layout, drops the component,
writes `positions` back, and verifies the result by re-reading the dashboard. The
verification checks the stored layout — expected charts present, no orphans,
no dangling references, valid ROOT-first ancestor chains — not `dashboard.slices`
directly, because Superset does not return that set on a dashboard GET.

## 2. Windmill (dedicated workspace, D11)

Windmill >= 1.484.0. The agent gets its own workspace `librechat-agent` with a
non-admin user as its only member, because (spike 6.6) a folder-scoped token's
schedule can run a script outside the folder; the workspace is the boundary.

Token scopes that work with the MCP endpoint (spike 6.6):

```json
["mcp:endpoints:listScripts,getScriptByPath,createScript,updateScript,runScriptByPath,listSchedules,getSchedule,createSchedule,updateSchedule,listJobs,getJob,getJobLogs",
 "mcp:scripts:/*", "mcp:flows:/*"]
```

The endpoint ignores API domain scopes (scripts:write:... gets 403). Keep
deleteScriptByPath and deleteScriptByHash out of the endpoint list: both are
admin-only and rejected for the non-admin token.

In LibreChat, set the api env:

    WINDMILL_MCP_URL=http://srv-captain--windmill:8000/api/mcp/w/librechat-agent/mcp
    WINDMILL_MCP_TOKEN=<the token>

## 3. Postgres MCP (read-only)

Create a SELECT-only role in the target database:

    CREATE ROLE librechat_reader LOGIN PASSWORD '...';
    GRANT CONNECT ON DATABASE yourdb TO librechat_reader;
    GRANT USAGE ON SCHEMA public TO librechat_reader;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO librechat_reader;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO librechat_reader;

Set the DSN on the `-pg-mcp` app (DATABASE_URI), redeploy, then set
PG_MCP_ENABLED=1 on the api app and redeploy (order matters; see the install
instructions). The DSN never enters the api container.

## 4. Backups (v1, manual)

Back up before every upgrade. In CapRover set Instance Count = 0 on the api
app (no writes), run the dump, then set Instance Count back to 1.

    # dump Mongo (name filter is anchored so it matches exactly one container)
    docker exec $(docker ps -qf name=^srv-captain--<app>-mongodb\.) mongodump \
      -u librechat -p <password> --authenticationDatabase admin --archive --gzip \
      > librechat-<date>.archive.gz

    # volumes
    docker run --rm -v <app>-uploads:/data:ro -v $PWD:/backup alpine tar czf /backup/uploads-<date>.tgz -C /data .
    docker run --rm -v <app>-images:/data:ro -v $PWD:/backup alpine tar czf /backup/images-<date>.tgz -C /data .

### 4.1 Restore

    # fresh install of the app first (same app name), then, with Instance Count = 0:
    docker exec -i $(docker ps -qf name=^srv-captain--<app>-mongodb\.) mongorestore \\
      -u librechat -p <password> --authenticationDatabase admin --archive --gzip --drop < librechat-<date>.archive.gz
    # volumes: untar into the fresh volumes
    docker run --rm -v <app>-uploads:/data -v $PWD:/backup alpine sh -c 'cd /data && tar xzf /backup/uploads-<date>.tgz --strip-components=0'

### 4.2 Verify after restore

    # login works, an old conversation opens, an uploaded file loads, a stored
    # user API key still works (spec 5.9). CREDS_KEY/CREDS_IV must match the
    # backed-up values - without them stored keys are unreadable.

## 5. Memory limits (servers that need them)

If your server is memory-constrained, give each app of the stack a memory
limit in CapRover (App Configs - Service Update Override):

    TaskTemplate:
      Resources:
        Limits:
          MemoryBytes: 1610612736

Apply it to `<app>`, `<app>-mongodb` and `<app>-pg-mcp` (1.5 GB each here). Store CREDS_KEY, CREDS_IV, the JWT secrets and the Mongo password (App Configs env view) somewhere safe right after install: without CREDS_* a restored install cannot read stored user API keys.

## 6. MCP change procedure (summary)

| Change | Steps |
|---|---|
| Windmill/Superset URL or token | Edit env on the api app, redeploy. Clearing the URL removes the entry. |
| Postgres on | DATABASE_URI on `-pg-mcp`, redeploy, then PG_MCP_ENABLED=1 on api, redeploy. |
| Postgres off | PG_MCP_ENABLED=0 on api, redeploy, then clear DATABASE_URI on `-pg-mcp`, redeploy. |
| Token rotation | Mint a new token, edit *_MCP_TOKEN, redeploy. |

## 7. Guardian Connector skills and prompts (optional, off by default)

Status: built and tested locally against the pinned image `librechat/librechat-api:v0.8.8`. Not deployed to production. Production rollout needs its own approval (section 7.7).

### 7.1 What ships

- Five skills, loaded from `/app/skills` through `DEPLOYMENT_SKILLS_DIR` (LibreChat's read-only deployment skills):
  - `gc-core` (always, while the switch is on): discovery order, metadata hygiene, sensitive coordinates, evidence rules.
  - `gc-mapeo` and `gc-alerts` (on by default when the switch is on).
  - `gc-kobo` and `gc-rastro` (opt-in).
  - `gc-install` is generated at boot. It lists the connection-name hints and the enabled families. It is marked unverified.
- Starter prompts, seeded into MongoDB as public prompt groups. Category is `gc-<family>`. One group per starter. Default set: 15 starters for core, mapeo and alerts.
- The source of every skill and prompt is in the repo: `skills/gc/<family>/SKILL.md` and `skills/gc/prompts/<family>.md`.
- Not shipped in v1: an automatically seeded "GC Analytics" agent. Build it by hand with `docs/gc-analytics-ui-recipe.md`.

### 7.2 Settings (api app environment, set from the template variables)

| Variable | Default | Meaning |
|---|---|---|
| `GC_SKILLS_ENABLED` | `0` | Master switch. Unset or `0` means off. Existing installs are never changed until this is set to `1`. |
| `GC_SKILL_MAPEO` | `1` | Mapeo skill and prompts. Used only when the master switch is `1`. |
| `GC_SKILL_ALERTS` | `1` | Alerts skill and prompts. Same rule. |
| `GC_SKILL_KOBO` | `0` | Kobo skill and prompts. Same rule. |
| `GC_SKILL_RASTRO` | `0` | Rastro skill and prompts. Same rule. |
| `GC_SKILLS_DB_WAREHOUSE` | empty | Optional connection-name hint, for example `Warehouse`. Letters, digits, space, dot, underscore, hyphen; 64 characters at most. |
| `GC_SKILLS_DB_RASTRO` | empty | Optional connection-name hint, for example `Rastro`. Same rule. |
| `DEPLOYMENT_SKILLS_DIR` | `/app/skills` | Fixed. Backed by the `<app>-skills` volume. |

Invalid values disable provisioning for that boot and print `GC_PROVISION_DEGRADED: flags` or `hints`. Chat still starts.

### 7.3 Boot behaviour

On every start, after the LibreChat config is validated and before the server starts (`scripts/librechat-boot.sh`, section "GC provisioning"):

1. Resolve and validate the flags and hints. Invalid input: provisioning is disabled for this boot.
2. Stage the skills in a temporary directory and validate them with LibreChat's own skill validators in the pinned image. A failed validation leaves the published copies as they were.
3. Publish the staged skills. A manifest of content hashes (`/app/skills/.gc-state/manifest.txt`) separates managed files from operator edits. Unchanged managed skills are updated. Edited skills are kept and reported.
4. Run the seeder (`/app/gc-seed/gc_seed.cjs seed`). It is always invoked, also when the switch is off, so previously published content is removed. It waits up to 90 seconds for MongoDB, has a 150-second wall-clock limit, and always exits 0.
5. Start the server.

Every failure prints one line that starts with `GC_PROVISION_DEGRADED: <area>:`. Read the api logs for that marker. Areas: `flags`, `hints`, `skills`, `seeder`, `prompts`, `acl`.

### 7.4 Public visibility: read before enabling

- Starter prompts are public. Every signed-in account can view them. If `ALLOW_REGISTRATION` is `true`, anyone who can register sees them. Set `ALLOW_REGISTRATION` to `false` after the first account exists.
- Skills are read-only and visible to every user who has skills enabled.
- Connection-name hints are text the model reads. They are public and unverified. Do not put secrets or private names in them.
- If `LLM_API_KEY` is set, every user's chat spends that key. Without it, each user brings their own key.
- Skills describe the Superset tools. They do not grant access. Access is decided by the Superset role of the Superset process (sections 1 and 1.1).
- Exact coordinates: the skills tell the model to aggregate and not publish exact positions. That is guidance, not a control. Access control is the Superset role.

### 7.5 Operating it

- Turn on or change settings: edit the variables, then redeploy the api app. The boot writes the skills, so a restart with the same settings does nothing new.
- Operator edit to a skill file: the file is kept, `GC_PROVISION_DEGRADED: skills` names it, and the skill stops being updated. To return it to managed content, remove its directory from the `<app>-skills` volume and redeploy. This path is not covered by the automated test.
- Operator edit to a seeded prompt in the UI: the code keeps the edit and reports it as a conflict on the next boot. This path is not covered by the automated test.
- Turn off: set `GC_SKILLS_ENABLED` to `0` and redeploy. Unchanged managed skills are removed and unchanged managed prompt groups are deleted (covered by the automated test). Edited prompts stay and lose public access; that branch is not covered by the automated test.
- The v0.8.8 image logs `PROMPT PERMISSIONS MIGRATION REQUIRED` on boot when prompt groups exist. Seeded groups are counted in that notice. It is a LibreChat notice, not a seeding failure. The migration command was not run in this work.
- Back up MongoDB and the `<app>-skills` volume before enabling, as in section 4.

### 7.6 What was verified (2026-10-13, local)

- Cold start with the switch on, before any user exists: four skills loaded from `/app/skills`; 15 starter groups seeded; the first registered account became `ADMIN`; no `users` document was created by the seeder.
- An ordinary account sees the 15 seeded groups in the prompt list.
- The public ACL row has the same field set and types as the row written by LibreChat's own share endpoint (`PUT /api/permissions/promptGroup/<id>` with `public: true`, role `promptGroup_viewer`).
- Repeat boot: no changes. Operator-edited skill: kept and reported. Switch off: managed content removed. Invalid switch: chat starts with the marker. MongoDB down at boot: chat starts with the marker after the 90-second wait.
- The Superset MCP gate was checked read-only: `checklist_missao_evu` (Warehouse, 122 columns) and `checklist_missao_evu_map` (lat/lon from the text location field) are present. Choice values were not sampled, because the gate exposes no row sampling without a chart.
- Automated: `npm run test_librechat` runs the generator cases and the GC matrix (`scripts/test_librechat_gc.js`). The live Mongo cases start a throwaway MongoDB container. Set `GC_TEST_SKIP_LIVE=1` to skip them.

Not verified: production; a chat that actually completes through the configured model with a seeded prompt; a live Superset write; the side tables `checklist_missao_evu__columns` and `__labels` (not registered as datasets).

### 7.7 Deviations and rollout

- Deviation from the plan: the seeded prompts have a fixed synthetic author id and no `users` row. A seeded user would make LibreChat's first-user admin bootstrap (`countUsers() === 0`) wrong, so the first real account would not be an admin. Decision: option A, per a Claude Opus 5.5 consult. Each seeded group also gets an owner ACL row for that synthetic id (role `promptGroup_owner`), so owner-scoped checks resolve. Local checks found no code path that joins prompts to their author, so no prompt is dropped. Option B (seed after the first admin exists) remains the fallback.
- Rollout to production needs explicit approval. Steps: back up MongoDB and the skills volume; set `ALLOW_REGISTRATION` to `false` after the first admin; pilot with the switch on for one install; then one full-definition update of the `chat` app that carries the command array, env, the skills volume and `DEPLOYMENT_SKILLS_DIR`. Check the domains afterwards, because the CapRover API can drop them on update.

## 8. What was verified against a real Superset 6.1.0 (2026-10-14)

The statements above were checked against a live `apache-superset==6.1.0`
stack (the same version, run locally in Docker with its own Postgres, Redis and
a second process for the MCP identity). Recorded here so later readers know
which claims are source-derived and which are empirically confirmed.

### 8.1 Tool set and RBAC, observed

- **24 MCP tools registered.** The superset process logged `Registered MCP tool:
  <name>` once per boot for exactly these 24, and no others: `add_chart_to_existing_dashboard`,
  `create_virtual_dataset`, `execute_sql`, `generate_chart`, `generate_dashboard`,
  `generate_explore_link`, `get_chart_data`, `get_chart_info`, `get_chart_preview`,
  `get_chart_type_schema`, `get_dashboard_info`, `get_database_info`,
  `get_dataset_info`, `get_instance_info`, `get_schema`, `health_check`,
  `list_charts`, `list_dashboards`, `list_databases`, `list_datasets`,
  `open_sql_lab_with_context`, `save_sql_query`, `update_chart`,
  `update_chart_preview`. `get_dashboard_data`, `manage_native_filters`,
  `remove_chart_from_dashboard`, `delete_chart`, `delete_dashboard`,
  `update_dashboard` and `update_dataset` were absent.
- **Discovery is search-based by default.** A fresh client's `tools/list` exposes
  only `health_check`, `get_instance_info`, `search_tools` and `call_tool`;
  `search_tools` finds the rest by name. Every tool takes a single `request`
  object, so a bare `page`/`page_size` argument is rejected as an unexpected
  keyword - wrap arguments in `{"request": {...}}`.
- **The role grants work as documented.** The agent account listed its dataset
  and only the database it was granted; it created a chart (`create_virtual_dataset`
  and `generate_chart` with `save_chart: true`) and a dashboard whose `created_by`
  is the agent, and the DB rows confirm the acting user is in `dashboard_user`
  and `slice_user` for those objects, with `dashboard_slices` holding the link.
- **Denials are explicit.** `execute_sql` failed with
  `Permission denied: can_execute_sql_query on SQLLab for user svc-chat-mcp`,
  and `save_sql_query` with `can_write on SavedQuery ...`. Neither permission is
  granted by the role, and neither tool exists in a form the role can use.
- **Tool visibility is not authorisation.** The restricted tools are still found
  by `search_tools` and only fail when called, confirming that a visible tool is
  not an authorised one.
- **Ownership is enforced on the REST write path too — but note what was
  observed.** The agent could not rename or delete a dataset owned by `admin`,
  and the call was refused. The refusal text was the *helper's* message
  (`the agent account does not own it`, `scripts/superset_dashboard_ctl.py`),
  because the helper checks ownership locally before sending the request — it
  never uses that check as an authorisation decision, `raise_for_ownership` in
  Superset is the authority. So the claim "Superset itself returned 403" was not
  proven by that observation. It remains **unverified** that a raw REST call with
  no local pre-check is refused by Superset's own `raise_for_ownership`; prove it
  with a bare `curl` as the agent account if it matters. Also, the line cites
  `DashboardPutSchema` for a *dataset* operation, which is the wrong schema.

### 8.2 The REST helper, exercised end to end

`show`, `rename-dashboard --title`, `rename-chart`, `rename-dataset`, `create-tab`,
`move-chart --tab`, `add-chart`, `set-filters`, `remove-chart` and `delete-chart`
were each run against the live instance with the agent account. Two commands were
**not** exercised live in that run: `delete-dashboard`, and `delete-dataset` — the
dataset available to the agent had dependants, so the dependency guard refused it,
which is the protected path but not a completed delete. Both are now covered by
the behavioural tests in `scripts/test_superset_dashboard_ctl.py` and by
`test/superset-e2e`. Observed, not assumed:

- `create-tab` on a **grid** dashboard converts it to tabs and **carries the
  existing charts over**; the result is `ROOT > TABS > TAB > ROW > COLUMN > CHART`
  with no dangling child ids and no lost charts.
- `remove-chart` detaches a chart while keeping it: the chart is gone from the
  layout and the dashboard's chart count drops, and the chart itself still exists.
- `rename-dashboard --description` is **refused** because `DashboardPutSchema`
  has no `description` field; letting it reach the server would only produce a
  400. Dataset and chart descriptions do work.
- `move-chart` with no `--tab` on an already-tabbed dashboard is refused, because
  ROOT may hold exactly one child (a GRID or a TABS).
- Existing `json_metadata` survives every layout write: native filters, colour
  scheme, refresh frequency, expanded slices and `filter_scopes` were all intact
  after `create-tab`, `move-chart` and `remove-chart`.
- Two CSRF ordering rules were found the hard way and are now documented in
  1.11.1: the token must be fetched before the `Cookie` header is built (its
  response re-issues the session cookie), and the cookie must be replayed by hand
  because Superset marks it `Secure` and urllib's cookie jar drops `Secure`
  cookies over plain `http://`.

### 8.3 Memory behaviour of the MCP process

Measured on the `superset mcp run` process (`VmRSS` of PID 1 inside the
container), 800 read-only MCP calls per run, plus a `generate_chart` per round:

| point | RSS | note |
|---|---|---|
| after boot | ~278 MiB | baseline |
| 80 calls | 285 MiB | warm-up |
| 400 calls | 290 MiB | |
| 800 calls | 297 MiB | end of run |

The marginal cost falls as the run proceeds (~89 MiB/1k calls at 80 calls, ~24
MiB/1k at 800), and a **restart returns the process to 285 MiB and re-traces the
same curve** - it does not resume from 297 and keep climbing. Thread count (17)
and open fds (10) were unchanged across runs.

Conclusion: **no leak signal.** The growth is per-session cache warm-up
(SQLAlchemy metadata, Superset metadata params, chart plugin registry) that
resets on restart. Budget a few hundred MiB per MCP process and treat a periodic
restart as cache hygiene, not a memory fix. This was measured on a small
instance; a wide one will warm more metadata, so re-measure rather than
extrapolate the absolute numbers.

### 8.4 What was NOT verified

- Production, and any instance with real data volume, users or row-level security.
- **The public token gate.** The harness ran entirely on loopback, so nothing
  tested the internet-facing JWT check. What a reader can check without
  credentials: `curl -i https://<mcp-host>/mcp` must answer `401`, and a POST
  with a wrong-key token and with an expired token must both be `401` too. That
  was confirmed against the live endpoint on 2026-10-15, but only from outside.
- **Superset's own `raise_for_ownership` on a raw REST write.** The refusal
  observed in 8.1 came from the helper's local pre-check, not from Superset. See
  the corrected bullet in 8.1.
- **HTTPS is covered locally, not against a public issuer:** `tls_check.sh`
  puts nginx in front of the stack terminating a self-signed cert, and the full
  REST helper suite runs against `https://localhost:18443` - 24/24, with the
  login handshake, the `X-CSRFToken` + `Secure` cookie path and the `Referer`
  check each asserted as a real call. The helper verifies the certificate chain,
  which is the correct production behaviour. What remains unverified is a
  **publicly-trusted** issuer and a **real edge proxy** - which is the exact path
  production takes.
- **Memory under real metadata volume.** Section 8.3 measured a small instance;
  a wide one warms more, so re-measure rather than extrapolate the numbers.
- RLS (`row_level_security` filters) and the multi-issuer `MCP_USER_RESOLVER`
  path (absent in 6.1.0 anyway).
- Concurrency beyond what the probe produced: no simultaneous multi-client load
  test was run, so no claim is made about throughput or pool sizing.

### 8.5 Known residual risks (decided, not defects)

These are accepted consequences of the 6.1.0 access model, recorded so they are
policy rather than surprise. All three are enforced or bounded by Superset's own
checks; none requires Admin.

1. **Adding a chart the agent does not own to a dashboard it does own creates a
   sharing relationship.** In stock 6.1.0, `UpdateDashboardCommand` checks
   *dashboard* ownership, not chart ownership, so an attach can place a chart
   belonging to someone else onto the agent's dashboard. That does not edit the
   chart's definition, does not re-home it from its owner's dashboards, and does
   not grant the agent edit rights on the chart. But any holder of a dashboard
   role on that dashboard can see the chart's data through it
   (`security/manager.py` dashboard `raise_for_access`). **Closed for the MCP
   tool in production (deployed 2026-10-15)**: the deployed image patches
   `add_chart_to_existing_dashboard` to run `raise_for_ownership(chart)` before
   the data check, so a foreign chart is refused with "not owned by the service
   user" (observed live 2026-10-16). The e2e harness carries the identical patch
   and asserts the refusal. **Still open for the helper's `add-chart` and
   `create-tab --charts`**: those are operator-run, so the residual is a policy
   rule for the operator, not an agent risk.
2. **Deleting a shared chart is refused rather than attempted.** The agent can
   delete a chart it owns, but only when that chart is on no dashboard at all,
   because `dashboard_slices.slice_id` is `ON DELETE CASCADE` and would remove it
   from other users' dashboards. The helper detects the containing dashboards
   from the chart GET and refuses. To delete such a chart, detach it from every
   dashboard first (`remove-chart` on each).
3. **A dataset delete is refused when anything depends on it, and refused again
   when its dependants cannot be determined.** `DeleteDatasetCommand` validates
   existence and ownership only, so without this guard an owned dataset referenced
   by another user's chart could be removed and break that chart.
