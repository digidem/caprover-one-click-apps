#!/bin/sh
# LibreChat one-click startup script (canonical source).
# Spec: specs/librechat-mcp.md 3.3. Template public/v4/apps/librechat.yml embeds
# this file byte-equal as element 3 of the api service `command` array; the
# repo test (scripts/test_librechat_config.sh) asserts that equality.
# CapRover template placeholders live only in the template's own fields (image
# tags, service names, env values), never inside this text. All user values
# arrive as env vars and are validated before any write.

set -eu

# librechat-data-provider and js-yaml resolve from these paths in the pinned
# image (specs/spike-images.md). Exported so the checks also work when the
# script runs from another working directory.
NODE_PATH="/app/node_modules:/app/api/node_modules${NODE_PATH:+:$NODE_PATH}"
export NODE_PATH

CONFIG_FILE="${CONFIG_PATH:-/app/librechat.yaml}"
export CONFIG_FILE
TMP_FILE="$CONFIG_FILE.tmp"

# ---------- pre-check: validate resolved env values before any file write ----
# Regexes mirror the 3.4 validRegex strings; scripts/test_librechat_config.sh
# asserts the two stay identical (spec 5.2b).
node -e '
var env = process.env;
var fail = function (name) {
  console.error("librechat-boot: invalid or missing variable: " + name);
  process.exit(1);
};
var re = {
  LLM_NAME: /^[\w .-]{1,32}$/,
  LLM_DEFAULT_MODEL: /^[\w.:\/-]{1,128}$/,
  LLM_MODELS: /^[\w.:\/-]{1,128}([,][\w.:\/-]{1,128}){0,31}$/,
  PG_MCP_ENABLED: /^[01]$/,
  LLM_API_KEY: /^[A-Za-z0-9_.~:-]{0,512}$/,
  WINDMILL_MCP_TOKEN: /^[A-Za-z0-9_.~-]{0,256}$/,
  SUPERSET_MCP_TOKEN: /^[A-Za-z0-9_.~=-]{0,4096}$/
};
var optional = { LLM_API_KEY: 1, WINDMILL_MCP_TOKEN: 1, SUPERSET_MCP_TOKEN: 1 };
Object.keys(re).forEach(function (name) {
  var value = env[name];
  if (optional[name] && (value === undefined || value === null)) value = "";
  if (value === undefined || value === null || !re[name].test(value)) {
    fail(name);
  }
});
var banned = /[\x27\x22\\\s]/;
var urlOk = function (raw) {
  if (banned.test(raw)) return false;
  var u;
  try { u = new URL(raw); } catch (e) { return false; }
  if (u.username || u.password) return false;
  var keys = [];
  u.searchParams.forEach(function (v, k) { keys.push(k); });
  for (var i = 0; i < keys.length; i++) {
    if (/^(token|api_key|apikey|access_token)$/i.test(keys[i])) return false;
  }
  if (u.protocol === "https:") return true;
  return u.protocol === "http:" && /^srv-captain--[a-z0-9-]+$/.test(u.hostname);
};
if (!env.LLM_BASE_URL || !urlOk(env.LLM_BASE_URL)) fail("LLM_BASE_URL");
if (env.WINDMILL_MCP_URL && !urlOk(env.WINDMILL_MCP_URL)) fail("WINDMILL_MCP_URL");
if (env.SUPERSET_MCP_URL && !urlOk(env.SUPERSET_MCP_URL)) fail("SUPERSET_MCP_URL");
'

# ---------- generation --------------------------------------------------------
# Concrete values (endpoint name, default model) are written as single-quoted
# YAML scalars from validated env; everything secret stays a literal ${VAR}
# placeholder that LibreChat resolves from process.env at runtime (spec 3.3).
API_KEY_LINE="      apiKey: 'user_provided'"
if [ -n "${LLM_API_KEY:-}" ]; then
  API_KEY_LINE="      apiKey: '\${LLM_API_KEY}'"
fi

MCP_PART=""
if [ "${PG_MCP_ENABLED}" = "1" ]; then
  MCP_PART="${MCP_PART}  postgres:
    type: sse
    url: '\${PG_MCP_URL}'
    initTimeout: 30000
"
fi
if [ -n "${WINDMILL_MCP_URL:-}" ]; then
  MCP_PART="${MCP_PART}  windmill:
    type: streamable-http
    url: '\${WINDMILL_MCP_URL}'
    initTimeout: 30000
"
  if [ -n "${WINDMILL_MCP_TOKEN:-}" ]; then
    MCP_PART="${MCP_PART}    headers:
      Authorization: 'Bearer \${WINDMILL_MCP_TOKEN}'
"
  fi
fi
if [ -n "${SUPERSET_MCP_URL:-}" ]; then
  MCP_PART="${MCP_PART}  superset:
    type: streamable-http
    url: '\${SUPERSET_MCP_URL}'
    initTimeout: 30000
"
  if [ -n "${SUPERSET_MCP_TOKEN:-}" ]; then
    MCP_PART="${MCP_PART}    headers:
      Authorization: 'Bearer \${SUPERSET_MCP_TOKEN}'
"
  fi
fi

{
  printf "version: '1.2.8'\n"
  printf 'cache: true\n'
  printf 'interface: {}\n'
  printf 'endpoints:\n'
  printf '  custom:\n'
  printf "    - name: '%s'\n" "$LLM_NAME"
  printf '%s\n' "$API_KEY_LINE"
  printf "      baseURL: '\${LLM_BASE_URL}'\n"
  printf '      models:\n'
  printf '        default:\n'
  printf "          - '%s'\n" "$LLM_DEFAULT_MODEL"
  OLDIFS=$IFS
  IFS=,
  for m in $LLM_MODELS; do
    if [ "$m" != "$LLM_DEFAULT_MODEL" ]; then
      printf "          - '%s'\n" "$m"
    fi
  done
  IFS=$OLDIFS
  printf '        fetch: false\n'
  printf '      titleConvo: false\n'
  if [ -n "$MCP_PART" ]; then
    printf 'mcpServers:\n'
    printf '%s' "$MCP_PART"
  fi
} > "$TMP_FILE"
mv "$TMP_FILE" "$CONFIG_FILE"

# ---------- post-check: validate the generated file against LibreChat's schema
node -e '
var fs = require("fs");
var yaml = require("js-yaml");
var dataProvider = require("librechat-data-provider");
var file = process.env.CONFIG_FILE;
var raw = fs.readFileSync(file, "utf8");
var doc;
try {
  doc = yaml.load(raw);
} catch (e) {
  console.error("librechat-boot: generated config is not valid YAML: " + e.message);
  process.exit(1);
}
var result = dataProvider.configSchema.strict().safeParse(doc);
if (!result.success) {
  console.error("librechat-boot: generated config failed LibreChat schema validation: " + JSON.stringify(result.error.issues));
  process.exit(1);
}
'

# ---------- GC provisioning (optional; soft-fail, never blocks chat) ----------
# Skills and starter prompts for Guardian Connector (scripts/gc_skills_bundle.sh).
# gc_main always returns 0; problems print GC_PROVISION_DEGRADED and chat starts.
# Invoked with "|| true" whether the master flag is on or off, so content that was
# published by an earlier boot is revoked when the flag goes off.
GC_SEED_DIR=/app/gc-seed
GC_STAGE=/app/.gc-stage
export GC_SEED_DIR GC_STAGE
# BEGIN GC PAYLOAD (generated by scripts/gc_skills_bundle.sh; edit the sources, not this block)
gc_stage_gc_core() {
  mkdir -p "$GC_STAGE/gc-core" || return 1
  cat > "$GC_STAGE/gc-core/SKILL.md" <<'EOF' || return 1
---
name: gc-core
description: Shared discovery and safety rules for Guardian Connector Superset work - find datasets by name, verify columns before querying, keep metadata fields out of charts, and protect sensitive coordinates.
---

# Guardian Connector core: discovery and safety

Guardian Connector (GC) deployments expose a Superset analytics stack through a set of MCP tools. This skill is the shared baseline every GC install gets: how to discover what data exists, how to keep ingestion metadata out of analysis, and how to avoid publishing sensitive locations. Read it before writing any query, virtual dataset, chart, or dashboard in a GC conversation.

## When to use this skill

Use it in any conversation that touches GC data: answering questions about observations or tracking data, building or editing charts and dashboards, creating virtual datasets, or explaining what an install contains. When another gc skill covers a more specific task, apply that skill on top of this one. This file defines the baseline that never gets skipped.

## Tool-call shape

Every tool listed in this skill takes exactly one argument object named `request`, for example `{"request":{"identifier":1}}`. Never spread parameters as separate top-level arguments. The available tools are: list_databases, get_database_info, get_schema, list_datasets, get_dataset_info, list_charts, get_chart_info, get_chart_data, get_chart_preview, generate_chart, update_chart, list_dashboards, get_dashboard_info, generate_dashboard, add_chart_to_existing_dashboard, create_virtual_dataset, generate_explore_link, execute_sql, and health_check. No other Superset tools exist in this family, so do not invent or assume others.

## Discovery workflow

Follow this order every time, even for questions that look simple.

1. Call list_databases to see which databases this install exposes.
2. Call list_datasets and filter the results by name to find candidate datasets for the question.
3. Call get_dataset_info or get_schema on each candidate and read the actual column names.
4. Only then write a query, virtual dataset, chart, or dashboard, using column names you have seen in tool output.

Never guess a table or column name. Table names vary per install; for example, an observations table may be named `comapeo_<project>_observations` with the project slug embedded, or it may not. Treat any naming pattern you have not confirmed in this install as not verified; confirm by discovery.

Superset dataset ids differ per install, so always resolve datasets by name through list_datasets and take the id from that same response. Never reuse a dataset id from a different install or an earlier conversation.

Datasets whose names contain probe, scratch, or DELETE_ME are test artifacts. Ignore them and do not chart them; mention them only if the user asks about test data.

## execute_sql is normally denied

The service user is normally RBAC-denied on SQLLab. If you call execute_sql you will usually get the error "Permission denied: can_execute_sql_query on SQLLab". Treat that as expected, not as a bug. Fall back to datasets and charts: use list_datasets and get_dataset_info to find data, create_virtual_dataset to shape it, and generate_chart or update_chart to present it. Quote the error if you report it, and do not keep retrying the same call.

## Database identity

A GC install typically exposes more than one database holding different domains: the warehouse database holds Guardian Connector ingestion data such as observations and survey submissions, and the rastro database holds rastro tracking data. Keep the domains apart. Do not build one chart that mixes tables from both databases unless the user has confirmed an explicit join key that exists on both sides. If a request seems to need both domains, ask which one matters first, or build two charts and label each one with its database and dataset.

## Metadata hygiene

Ingestion pipelines add bookkeeping columns that are metadata, not signal.

- Frizzle adds `_topic`.
- Kobo and ODK add underscore-prefixed fields such as `_id`, `_uuid`, `_submission_time`, `_attachments`, `_tags`, `_status`, `_submitted_by`, `_xform_id_string`, `_validation_status`, and `_notes`, plus the `meta` structure with `instanceID`.
- Mapeo exports add dollar-prefixed fields such as `$created`, `$modified`, `$version`, and `$photos`.

Keep these fields out of charts, aggregations, and summaries unless the user explicitly asks for them. The exception is a table that is meant to be a faithful export: there, never drop metadata columns silently. Keep them, and say in your answer that you kept them. When you do exclude metadata from an analysis, say so in one line so the reader knows the column list was curated rather than complete.

## Sensitive coordinates

Exact coordinates of people, boats, or Indigenous territories are sensitive data. Prefer aggregates: counts by category, time bucket, or named area. Do not put raw latitude and longitude on a dashboard, in a chart, or in an answer unless the user explicitly asked for raw coordinates. If a request would expose exact locations, warn before building anything and offer the aggregated alternative. This applies when relaying results too: if get_chart_data or get_chart_preview returns raw points for a chart you did not build, say so instead of passing the coordinates along silently.

## Build rules

- One chart with a filter beats many near-identical charts. When the user wants the same measure across several categories, build a single chart with a category filter or breakdown instead of a chart per category.
- Label entities with friendly names when a friendly-name column exists in the verified schema. If none exists, use the raw column and say that no friendly-name column was found.
- In every answer, state which dataset and which columns a chart uses.
- If a claim rests on configured hints rather than something a tool returned in this conversation, state that it is not verified; confirm by discovery.

## Evidence and error handling

Report the row count and the dataset name behind every number you give. A number without its dataset is not an answer. If a tool call fails, quote the error text and stop; do not invent a fallback, do not substitute a guessed table, and do not present an unverified number as if it were measured. When the failure blocks the task, say what failed and ask the user how to proceed.

## Quick reference

- Discover first: list_databases, then list_datasets filtered by name, then get_dataset_info or get_schema.
- Never guess table or column names, and never reuse a dataset id from another install.
- execute_sql is normally RBAC-denied on SQLLab; fall back to datasets, virtual datasets, and charts.
- Metadata fields stay out of charts unless the user asks; faithful exports keep every column.
- Aggregate before you publish; raw coordinates need an explicit user request and a warning first.
- Every number reports its dataset and row count; on tool failure, quote the error and stop.
EOF
}

gc_stage_gc_mapeo() {
  mkdir -p "$GC_STAGE/gc-mapeo" || return 1
  cat > "$GC_STAGE/gc-mapeo/SKILL.md" <<'EOF' || return 1
---
name: gc-mapeo
description: Query and chart CoMapeo and Mapeo field observations stored in the Guardian Connector warehouse through the Superset MCP tools; use it for any question about observation counts, categories, geometry, or tracks.
---

# Guardian Connector Mapeo Observations

This skill covers CoMapeo and Mapeo field observations that the Guardian Connector (GC) pipeline exports into the analytics warehouse, as queried through the Superset MCP tools. Use it whenever a question mentions Mapeo or CoMapeo observations, observation categories or icons, patrol tracks, observation maps, or field activity reporting for a project.

## Tooling and access rules

All reads go through the Superset MCP tools: list_databases, get_schema, list_datasets, get_dataset_info, get_database_info, list_charts, get_chart_info, get_chart_data, get_chart_preview, generate_chart, update_chart, list_dashboards, get_dashboard_info, generate_dashboard, add_chart_to_existing_dashboard, create_virtual_dataset, generate_explore_link, execute_sql, and health_check. Call each tool with a single argument object named request.

The execute_sql tool is normally RBAC-denied for the service user, and the call fails with the error "Permission denied: can_execute_sql_query on SQLLab". Treat that failure as expected rather than as a bug. Fall back to datasets and charts: locate data with list_datasets, confirm columns with get_dataset_info, and answer quantitative questions with charts built by generate_chart and read back with get_chart_data or get_chart_preview.

If Superset calls fail in unexpected ways, call health_check first and report its result to the user.

## Finding the right dataset

Superset dataset ids differ per install. Never hardcode or guess a dataset id; always call list_datasets and match the dataset by name.

The verified observation dataset in this install is `comapeo_evu_observations`. Other installs carry tables named `comapeo_<project>_observations`; they belong to the same family, but their column lists can differ, so confirm with get_dataset_info before relying on any column there.

Ignore any dataset whose name contains probe, scratch, or DELETE_ME. Those are test artifacts from pipeline checks and must not appear in answers or dashboards.

## Columns of comapeo_evu_observations

The verified column list is: _id, data_source, schema_name, project_name, category_icon, project_id, terms, original_version_id, altitude, deleted, heading, created_by, manual_location, updated_at, color, attachments, accuracy, position_timestamp, g__coordinates, created_at, links, g__type, speed, type, access, updated_by, mocked, docId, category, notes, version_id, infrastructure, altitude_accuracy, acampamento, and category_id.

They group as follows.

- Identity and provenance columns are _id, docId, version_id, original_version_id, links, data_source, schema_name, project_id, project_name, created_by, updated_by, and mocked.
- Category and content columns are category, category_id, category_icon, terms, notes, type, access, infrastructure, acampamento, and color.
- Geometry and sensor columns are g__type, g__coordinates, altitude, altitude_accuracy, accuracy, heading, speed, manual_location, and position_timestamp.
- Lifecycle and media columns are deleted, created_at, updated_at, and attachments.

The columns infrastructure and acampamento look specific to the EVU project category set. Do not assume that equivalent columns exist on other installs.

## Mapping from the Mapeo GeoJSON export

The GC schema documentation describes the Mapeo GeoJSON export as objects with four top-level keys: type, geometry, id, and properties. Tags live in properties. The warehouse flattens that shape, which matters when a user pastes an export or asks about raw Mapeo field names.

- The main category key in the export, categoryId, appears as category_id in the warehouse, with the readable label in category and the icon reference in category_icon.
- The field-entry free text is notes in both the export and the warehouse.
- Photos are `$photos` in the export and attachments in the warehouse.
- The export also carries dollar-prefixed metadata keys: `$created`, `$modified`, `$version`, and `$photos`. The warehouse exposes created_at, updated_at, version_id, and attachments as flat counterparts, but the key-by-key correspondence is not verified; confirm by discovery if a precise mapping matters.

## Data hygiene rules

Exclude soft-deleted rows. The deleted column marks them, so filter to deleted being false unless the user explicitly asks about deletion history or data quality.

Filter by project whenever a question names one. project_name and schema_name separate projects, and you must not assume that the dataset found first is the project the user means.

Never present a warehouse row count as total field activity. Observation counts are rows that have synced to the warehouse; devices offline in the field sync later, so recent activity is undercounted by an unknown amount. Say this when reporting counts.

## Geometry and coordinates

The columns g__type and g__coordinates hold the observation geometry. Assume GeoJSON order, longitude first and latitude second, but confirm by inspecting one row before producing any map, buffer, or distance figure.

The manual_location column flags observations whose position was placed by hand rather than captured by GPS. When a user asks about positional quality, use accuracy, and report altitude together with altitude_accuracy.

## Time axes

Three time columns exist: created_at, updated_at, and position_timestamp. Read them as the creation time, the last edit time, and the time of the position fix; that reading follows the field names and is not verified; confirm by discovery if the distinction could change an answer.

Every time-series chart must state which of the three columns it uses, in the chart title or description. Never leave the axis implicit.

## Tracks

A `comapeo_evu_tracks` table exists in the warehouse according to the GC notes. Its columns are not verified; confirm by discovery by calling get_dataset_info on it, found through list_datasets, before using it in any chart.

Tracks are patrol tracks recorded in CoMapeo or Mapeo. They are not mesh (rastro) tracks, and the two families describe different things, so never mix them in one chart or dashboard, and say so if a user conflates them.

## Category questions

Group category questions by category or category_id, and always label results with the human-readable category value rather than the raw id. Treat category_icon as a pointer to icons and use it only when the user asks about iconography.

## Chart and dashboard workflow

The working loop is: list_datasets to find the dataset and its id; get_dataset_info to confirm the columns you plan to use; generate_chart to build the chart; get_chart_data or get_chart_preview to verify the numbers before presenting them; and finally generate_dashboard or add_chart_to_existing_dashboard to assemble the result. Use update_chart for revisions and generate_explore_link to hand over a clickable Superset URL.

Use create_virtual_dataset for reusable filtered slices, for example one project with deleted rows excluded, so that every chart on a dashboard shares the same base filter.

Starter charts worth proposing:

- Chart observations per month on created_at, filtered to one project and excluding deleted rows.
- Chart observations per category, labeled with the category name.
- Chart the share of observations carrying attachments, as a photo evidence indicator.

## Known limits

Row counts lag field reality because of sync delays, execute_sql is unavailable to the service user, and the tracks table columns are unverified. State these limits whenever they affect an answer.
EOF
}

gc_stage_gc_alerts() {
  mkdir -p "$GC_STAGE/gc-alerts" || return 1
  cat > "$GC_STAGE/gc-alerts/SKILL.md" <<'EOF' || return 1
---
name: gc-alerts
description: Reading alert state from the rastro database via Superset in Guardian Connector, covering active alerts, episode history, alert kinds, and what the alert engine does not do.
---

# Guardian Connector alerts: reading alert state in the rastro database

Use this skill when a user asks about alerts in Guardian Connector: what is currently firing, why a node or gateway was flagged, how long a condition has lasted, or how often it has happened. Answers come from the `alert_state` table of the rastro database, reached through the Superset MCP tools.

## The alert_state table

The table holds one row per alert episode.

- `key`: TEXT, primary key, formatted as "kind:subject", for example "gateway_mudo:3" or "bateria_critica:17".
- `node_num`: BIGINT, the subject of the alert. For `bateria_critica` it is the node. For `gateway_mudo` the engine stores the gateway identifier in this column too, so do not assume it is a node: check the `nodes` table before joining.
- `kind`: TEXT, the condition that fired, for example `gateway_mudo` or `bateria_critica`.
- `since`: TIMESTAMPTZ, when the condition was first raised for this episode.
- `last_notified`: TIMESTAMPTZ, when the most recent notification attempt was recorded.
- `cleared_at`: TIMESTAMPTZ, when the condition stopped being true. Null while the alert is active.

## Episodes, not events

`alert_state` is a state table, not an event log. The engine raises a row once, when a condition becomes true. While `cleared_at` is null the alert stays active and is not raised again. When the condition stops being true the engine sets `cleared_at`, closing the episode; if the same condition returns later it raises a new row.

This decides how a question is answered:

- "What is active now?" reads rows where `cleared_at` is null.
- "How often did X happen?" counts episodes, one per row, timed by `since`.
- "How long has this lasted?" is `now()` minus `since` for active rows, or `cleared_at` minus `since` for closed episodes.

## Kinds currently evaluated

`gateway_mudo` fires for a gateway with no uplink for longer than `RASTRO_GATEWAY_SILENT_SECS`, which defaults to 3600 seconds. The subject in `node_num` and in `key` identifies the gateway.

`bateria_critica` fires only for FIXED nodes when the latest `node_power` reading shows `battery_level` below `RASTRO_BATTERY_LOW_PCT` (default 20) or voltage below `RASTRO_BATTERY_MIN_VOLTS` (default 3.55 volts). Mobile boats never evaluate this kind, so a low battery on a mobile node produces no alert and must not be reported as one.

## Retired kinds

`sem_fix`, `posicao_parada`, and `movel_ausente` are retired. The engine no longer evaluates them, and it clears their old active rows itself. Rows that still carry these kinds are historical episodes only; never report them as current alerts.

## Fixed versus mobile is not in the database

Which nodes are fixed comes from the environment variable `RASTRO_FIXED_NODES`, not from the schema. No chart or query can reproduce that classification from the database alone. If a question depends on it, ask the operator for the list, or present per-node results without claiming which nodes are fixed. The only safe inference is the engine's own guarantee that `bateria_critica` applies to fixed nodes only.

## Names and joins

Join `alert_state.node_num` to the `nodes` table on `node_num` for names, and label with `COALESCE(friendly_name, node_id)` so rows lacking a friendly name still show the node id. For `gateway_mudo` rows, a join can return nothing; label them with the raw `node_num` (the gateway identifier) and say that it is a gateway.

## Notifications are not delivery

The alert engine records state only. Delivery by push or email is outside the alert engine. `last_notified` means a notification attempt was recorded at that time; it never proves a message was delivered, so avoid telling the user that anyone was reached.

## Flight geofence alerts are a separate system

Aircraft and flight-geofence alerts live in a separate SQLite database in a separate repository. They are not in the rastro database and the Superset tools cannot see them. If the user asks about aircraft events, say this plainly instead of querying rastro.

## Discovery before querying

Superset dataset ids differ per install, so never hardcode them. Start with `list_databases` and `get_database_info`, and `health_check` if the connection itself is in doubt. Find datasets by name with `list_datasets`, then confirm columns with `get_dataset_info`; `get_schema` helps for table-level detail. Ignore any dataset whose name contains "probe", "scratch", or "DELETE_ME"; those are test artifacts.

Every Superset tool takes one argument object named `request`, for example `{"request": {"identifier": 1}}`.

## SQL for active alerts

```sql
SELECT a.kind,
       COALESCE(n.friendly_name, n.node_id) AS node_label,
       a.node_num,
       a.key,
       a.since,
       a.last_notified,
       now() - a.since AS active_for
FROM alert_state a
LEFT JOIN nodes n ON n.node_num = a.node_num
WHERE a.cleared_at IS NULL
ORDER BY a.since ASC;
```

This is a read-only SELECT. It runs only where `execute_sql` is allowed. In this deployment `execute_sql` is normally RBAC-denied for the service user with the error "Permission denied: can_execute_sql_query on SQLLab". When that error appears, do not retry the call; fall back to datasets and charts.

## Fallback: datasets and charts

1. Find the rastro dataset by name with `list_datasets` and read its columns with `get_dataset_info`.
2. If a suitable alert dataset already exists, use it; otherwise create one with `create_virtual_dataset`, pasting the SELECT above as its SQL.
3. Build the view with `generate_chart` as a table or a bar chart grouped by `kind`, then check the numbers with `get_chart_info` and `get_chart_data`.
4. Adjust with `update_chart`, or place it using `list_dashboards`, `get_dashboard_info`, `generate_dashboard`, and `add_chart_to_existing_dashboard`.
5. `generate_explore_link` returns a clickable URL for the user, and `get_chart_preview` confirms the chart renders. `list_charts` finds earlier alert charts worth reusing.

Episode counting works the same way: the virtual dataset SQL becomes a count grouped by `kind` with a date bucket on `since`, rendered by `generate_chart` as a time bar chart.
EOF
}

gc_stage_gc_kobo() {
  mkdir -p "$GC_STAGE/gc-kobo" || return 1
  cat > "$GC_STAGE/gc-kobo/SKILL.md" <<'EOF' || return 1
---
name: gc-kobo
description: Answer questions about KoboToolbox mission-checklist submissions in the Guardian Connector warehouse using Superset MCP datasets and charts; covers checklist_missao_evu columns, teams, supplies, and locations.
---

# gc-kobo

KoboToolbox / ODK form submissions loaded into the Guardian Connector (GC) warehouse, queried through the Superset MCP tools. The main dataset is `checklist_missao_evu`, the EVU mission checklist with 122 columns in the Warehouse database; `checklist_missao_evu_map` is its map variant with numeric coordinates. All tools take a single request object as their argument, for example `{"request": {}}`.

## What this dataset is

One row per Kobo submission of the EVU mission checklist: which checklist was performed, when the mission starts and ends, who took part, and stock checks covering fuel and lubricants, machines and equipment, communication gear, tools, and food. Field labels are Portuguese. The warehouse loader sanitized column names: accents and punctuation become underscores or are dropped, giving names like `Embarca_o` and `INICIO_DA_MISS_O`. Never correct the spelling in queries; quote names exactly as they are listed in this skill. Group fields from the Kobo form appear twice, once under the base name and once with a `__group_<hash>` suffix where the hash is the Kobo group id, and nested groups chain the suffixes (for example `__group_dh9sh33__group_ch9gb66`). Those suffixed columns duplicate the labeled group path; this skill uses the base, unsuffixed names as the primary reference and treats the suffixed ones as duplicates holding the same values. Repeat groups are not visible as separate tables in this export, so repeat analysis is not verified; confirm by discovery.

## Discovery steps

1. Call `health_check` to confirm the MCP server is reachable before anything else.
2. Call `list_databases`, then `get_database_info` or `get_schema`, to locate the Warehouse database.
3. Call `list_datasets` and find datasets by name, because dataset ids differ per install and must never be hardcoded. Ignore any dataset whose name contains `probe`, `scratch`, or `DELETE_ME`; those are test artifacts.
4. Call `get_dataset_info` on `checklist_missao_evu` and on `checklist_missao_evu_map` to confirm the columns still match this skill before relying on them.
5. `list_charts`, `get_chart_info`, `get_chart_data`, `get_chart_preview`, `list_dashboards`, and `get_dashboard_info` show what is already published. `generate_chart`, `update_chart`, `add_chart_to_existing_dashboard`, and `generate_dashboard` create or extend charts and dashboards. `create_virtual_dataset` and `generate_explore_link` support deeper analysis.
6. `execute_sql` is normally RBAC-denied for the service user with the error "Permission denied: can_execute_sql_query on SQLLab". Do not retry it; fall back to datasets and charts.

## Metadata to keep out of summaries

These columns identify rows, devices, and the form itself. Exclude them from aggregates and per-team breakdowns.

| Columns | Notes |
| --- | --- |
| `_id`, `_uuid`, `_submission_time` | Row id, submission UUID, and arrival time. Use `_submission_time` for time series. |
| `_submitted_by`, `deviceid` | Submitter account and device identifier. |
| `_status`, `_validation_status`, `_attachments`, `_tags`, `_notes` | Kobo submission state, not mission content. |
| `_xform_id_string`, `__version__`, `instanceID__meta`, `uuid__formhub` | Form id, form version, Kobo instanceID with the separator flattened to `__`, and the formhub UUID. |
| `_topic` | Frizzle ingestion topic. |
| `start`, `end` | Form record-keeping for when the form was opened and closed, not mission times. |
| `g__type`, `g__coordinates` | Geometry added by the warehouse; not verified; confirm by discovery before relying on them. |

## Column groups by theme

### Mission start

| Columns | Notes |
| --- | --- |
| `Qual_checklist_voc_vai_realizar`, `Selecione_se_esta_iniciando_ou` | Which checklist is performed and whether the form marks a start or an end. Choice value semantics were not sampled; chart distinct values before reporting meanings. |
| `INICIO_DA_MISS_O`, `PREVIS_O_PARA_O_FIM_DA_MISS_O` | Mission start and expected end. |

### End of mission

| Columns | Notes |
| --- | --- |
| `FIM_DA_MISS_O`, `FIM_DA_MISS_O_001` | Mission end times; the `_001` suffix probably marks a repeated question; confirm the wording in the labels table before treating it as a second end time. |

### Team

| Columns | Notes |
| --- | --- |
| `Monitores`, `Nome_do_responsavel_eencher_o_formul_rio` | Monitors on the mission and the person responsible for filling the form. |
| `EQUIPE_S_DA_MISS_O`, `EQUIPE_S_DA_MISS_O__group_ew7it43` | Team or teams of the mission. |
| `Equipe_Regional_Curu_a`, `Equipe_Regional_Itaquai`, `Equipe_Regional_Itaquai__group_ew7it43` | Regional teams Curuá and Itaguaí; Curuá has no grouped copy in this export. |
| `Equipe_Operacional_Atalaia`, `Equipe_Operacional_Atalaia__group_ew7it43` | Operational team Atalaia. |
| `Nome_e_descri_o_dos_OUTROS_participantes`, `Nome_e_descri_o_dos_OUTROS_participantes__group_ew7it43` | Other participants as free text. |

### Fuel and lubricants

| Columns | Notes |
| --- | --- |
| `CHECK_LIST_COMBUST_VEL_E_LUB`, `CHECK_LIST_COMBUST_VEL_E_LUB__group_nr9gf07` | Checklist headers of the fuel and lubricants block. |
| `Gasolina`, `Gasolina__group_nr9gf07` | Gasoline. |
| `Quantidade_de_Diesel`, `Quantidade_de_Diesel__group_nr9gf07` | Diesel. |
| `Quantidade_de_leo_para_motor_4t`, `Quantidade_de_leo_para_motor_4t__group_nr9gf07` | Oil for four-stroke motors. |
| `Quantidade_de_leo_para_motor_2t`, `Quantidade_de_leo_para_motor_2t__group_nr9gf07` | Oil for two-stroke motors. |
| `Quantidade_de_leo_para_motor_DIESEL`, `Quantidade_de_leo_para_motor_DIESEL__group_nr9gf07` | Oil for diesel motors. |
| `Quantidade_de_leo_90_para_rabada`, `Quantidade_de_leo_90_para_rabada__group_nr9gf07` | SAE 90 oil for longtail (rabeta) drives. |
| `Quantidade_de_Graxa_`, `Quantidade_de_Graxa___group_nr9gf07` | Grease. |
| `Quantidade_de_tambores_de_200l`, `Quantidade_de_tambores_de_200l__group_nr9gf07` | 200-liter drums. |
| `Quantidade_de_gal_es_timbo_`, `Quantidade_de_gal_es_timbo___group_nr9gf07` | Timbo containers. |

### Machines and equipment

| Columns | Notes |
| --- | --- |
| `CHECK_LIST_M_QUINAS_E_EQUIPA`, `CHECK_LIST_M_QUINAS_E_EQUIPA__group_dh9sh33` | Checklist headers of the machines and equipment block. |
| `M_QUINAS_E_EQUIPAMENTOS`, `M_QUINAS_E_EQUIPAMENTOS__group_dh9sh33` | Machines and equipment in use. |
| `Outras_maquinas_e_equipamentos`, `Outros__group_dh9sh33` | Free-text other machines and equipment; the base and grouped fields have different names. |
| `M_QUINAS_E_EQUIPAMENTOS_001__group_gy0se63__group_lk2wb32`, `Horas_do_motor_250__group_gy0se63__group_lk2wb32`, `Observa_es__group_gy0se63__group_lk2wb32` | Nested group with chained suffixes: machine selection, motor 250 hours, observations. |
| `MAQ_E_EQUIP_EQ_OPERACI__group_dh9sh33__group_ch9gb66`, `Verificar_leo_do_gerador__group_dh9sh33__group_ch9gb66`, `Sistema_solar__group_dh9sh33__group_ch9gb66` | Operational block: machines, generator oil check, solar system. |
| `Voltagem_das_baterias_do_sistema_solar___group_dh9sh33__group_c`, `Horas_do_250_MAPINGUARI__group_dh9sh33__group_ch9gb66`, `Rabetas_Diesel__group_dh9sh33__group_ch9gb66` | Battery voltage, where the column name is truncated at the 63-character identifier limit and must be quoted verbatim, plus motor 250 MAPINGUARI hours and diesel longtails. |
| `Verificar_leo_do_motor_diesel__group_dh9sh33__group_ch9gb66`, `Motor_15_hp_verificar_motor__group_dh9sh33__group_ch9gb66`, `_leo_da_rabada__group_dh9sh33__group_ch9gb66` | Diesel motor oil check, 15 hp motor check, and longtail oil. |
| `Observa_es_gerais_EQ_OPER__group_dh9sh33__group_ch9gb66` | General observations of the operational block. |

### Communication

| Columns | Notes |
| --- | --- |
| `CHECK_LIST_COMUNICA_O_E_REGI`, `CHECK_LIST_COMUNICA_O_E_REGI__group_lq2zp69`, `COMUNICA_O_E_REGISTROS`, `COMUNICA_O_E_REGISTROS_001__group_lq2zp69` | Checklist headers of the communication and records block. |
| `COMUNICA_O_E_REGISTROS__group_lk2wb32`, `COMUNICA_O_E_REGISTROS_002__group_lk2wb32` | Communication and records selection inside the nested group. |
| `Outros_equipamento_d_munica_o_e_registros`, `Outros_equipamento_d_munica_o_e_registros__group_lq2zp69` | Free-text other communication equipment. |
| `Comunic_e_Regis_EQ_OPERAC__group_ch9gb66` | Communication header of the operational block. |

### Tools

| Columns | Notes |
| --- | --- |
| `CHECK_LIST_FERRAMENTAS_MEC_N`, `CHECK_LIST_FERRAMENTAS_MEC_N_001`, `CHECK_LIST_FERRAMENTAS_MEC_N__group_ra2tj01`, `CHECK_LIST_FERRAMENTAS_MEC_N_001__group_ra2tj01` | Mechanical-tool checklist headers: base name, duplicate, and grouped copies. |
| `Outras_ferramentas` | Other tools as free text. |

### Food supplies

| Columns | Notes |
| --- | --- |
| `CHECK_LIST_ALIMENTA_O`, `CHECK_LIST_ALIMENTA_O__group_lw7wv24` | Checklist headers of the food block. |
| `SAL_KG`, `SAL_KG_001`, `ARROZ_KG`, `FARINHA_KG`, `FEIJ_O_KG`, `MACARR_O_KG`, `BOLACHA_KG`, `SAL_KG__group_lw7wv24`, `SAL_KG_001__group_lw7wv24`, `ARROZ_KG__group_lw7wv24`, `FEIJ_O_KG__group_lw7wv24`, `FARINHA_KG__group_lw7wv24`, `MACARR_O_KG__group_lw7wv24`, `BOLACHA_KG__group_lw7wv24` | Staples in kilograms: salt in two fields, rice, cassava flour, beans, pasta, biscuits. |
| `FRANGO_KG`, `CALABRESA_KG`, `CALABRESA_KG_001`, `CALABRESA_KG_002`, `LEITE_EM_P_KG`, `FRANGO_KG__group_lw7wv24`, `CALABRESA_KG__group_lw7wv24`, `CALABRESA_KG_001__group_lw7wv24`, `CALABRESA_KG_002__group_lw7wv24`, `LEITE_EM_P_KG__group_lw7wv24` | Proteins in kilograms: chicken, sausage in three fields, powdered milk. |
| `_LEO_KG`, `_LEO_KG__group_lw7wv24`, `PIMENTA_DO_REINO_KG`, `ALHO_KG`, `COLORAL_KG` | Seasonings: oil, black pepper, garlic, colorau. Only pepper, garlic, and colorau have no grouped copies in this export. |

Other columns: `Embarca_o`. The name suggests the vessel or boat used, but its value semantics were not sampled, so chart distinct values before reporting what it holds.

## Location handling

`Record_your_current_location` holds a text value in the form "lat lon", space separated, with latitude first. The virtual dataset `checklist_missao_evu_map` derives `latitude` from the first part and `longitude` from the second part and should be used for any coordinates or map chart, instead of parsing the text field ad hoc. Coordinates of field teams are sensitive: keep them out of summaries for audiences beyond the mission coordinators, prefer counts by team or area, and ask before plotting exact points anywhere shared.

## Common questions

- How many submissions per month and per team: chart `checklist_missao_evu` with `_submission_time` on the time axis and `EQUIPE_S_DA_MISS_O` as the grouping, using `generate_chart`, then read results back with `get_chart_data`.
- What supplies went out: chart the food and fuel quantity columns per submission and show raw values; quantities by item matter more than averages here.
- Where missions started: use `checklist_missao_evu_map`, following the sensitivity rules above.
- What a choice value means: value semantics were not sampled, so build a dataset chart of distinct values for the column in question before reporting any meaning.
- Choice labels: the side tables `checklist_missao_evu__columns` and `checklist_missao_evu__labels` are reported in the GC notes as holding column metadata and choice labels, but they are not registered as Superset datasets, so they could not be verified through the gate; not verified; confirm by discovery. Read choice labels from them when they exist, and show raw values when they do not.
EOF
}

gc_stage_gc_rastro() {
  mkdir -p "$GC_STAGE/gc-rastro" || return 1
  cat > "$GC_STAGE/gc-rastro/SKILL.md" <<'EOF' || return 1
---
name: gc-rastro
description: Rastro boat-tracking analytics for Guardian Connector; use when building Superset datasets, charts, or dashboards over the rastro mesh database, node positions, and device telemetry.
---

# Rastro analytics (mesh boat tracking)

Rastro is a Meshtastic mesh of boat and radio nodes reporting GPS positions and device
telemetry over MQTT into a PostgreSQL database named `rastro`, which is exposed to
Superset for analytics. This skill covers the data model, the validated house rules for
charting it, and how to drive the Superset tools against it. Every Superset tool takes
a single request object as its one argument, for example {"request": {"identifier": 1}}.

## Databases: know which one you are in

The PostgreSQL server hosts two databases that matter for analytics.

- `rastro` holds the mesh telemetry: `nodes`, `positions`, `device_telemetry`, and the
  view `vw_ultima_posicao`. Boat and node analytics live here. The tables sit in a
  dedicated schema `rastro`, not `public`; the schema is exposed to analytics through
  the read-only role `rastro_viewer`, whose search path resolves the plain table names.
  Treat that role as a server-side grant, never as a login credential. The same server
  also hosts databases named `guardianconnector`, `postgres`, `superset_metastore`,
  `warehouse`, and `windmill`; only `rastro` and `warehouse` are analytics targets.
- `warehouse` holds CoMapeo and EVU surveillance exports: `comapeo_evu_observations`,
  `comapeo_evu_tracks`, tables whose names start with `comapeo_equipe_de_vigil` and
  `checklist_missao_evu`, and `mapeo_data`. That is a different domain (community
  monitoring patrols) with a different identity model, and `comapeo_evu_tracks` there is
  NOT mesh track data.

Never mix the two databases in one chart without an explicit join key.

## The domain in one paragraph

Each row of `positions` is one GPS fix from one node, and a track is derived by ordering
the fixes of one node in time. There is no separate mesh tracks table and no mileage
table, so distance is always derived from consecutive positions. The `comapeo_evu_tracks`
table in the warehouse database is CoMapeo patrol data and is unrelated to boat tracks.

## Core tables

- `nodes` — one row per mesh node.
  - `node_num` BIGINT primary key, which is the packet "from" value; `node_id` TEXT
    unique, for example `!0badf00d`.
  - `friendly_name` is the boat or node name from the fleet names file. Suffixes in real
    names mark device placement: barco is hull, teto is roof, torre is tower, movel is
    vehicle, cartao is card.
  - `first_seen`, `last_seen`.
- `positions` — GPS fixes; this is the track source.
  - Key `node_num` references `nodes`. `pos_time` is TIMESTAMPTZ from the device clock,
    with `time_source` recording `device` or a `gateway` fallback.
  - Use the generated `lat` and `lon` double columns, derived from the `lat_i` and
    `lon_i` integers (degrees scaled by 10^7).
  - Quality columns: `sats_in_view`, `snr`, `rssi`, `hdop`, `pdop`, `ground_speed_ms`,
    `ground_track_deg`, `altitude_m`.
  - Rows are deduped on (`node_num`, `pos_time`). `received_at` is the gateway clock and
    is independent of the device clock.
- `device_telemetry` — device health.
  - Key `node_num`. `telem_time`, `battery_level` (percent), `voltage`, `channel_util`,
    `air_util_tx`, `uptime_s`. Deduped on (`node_num`, `telem_time`).
- `vw_ultima_posicao` — a view, ready to use.
  - The latest fix plus the latest battery per node, one row per node.
  - The name is already resolved to `COALESCE(friendly_name, node_id)` in a column
    named `nome`.

## Finding databases, datasets, and charts

Superset database and dataset ids differ per install. Never hardcode an id and never
trust an id quoted anywhere else; find things by name instead.

- Find the rastro database by name with list_databases and inspect it with
  get_database_info.
- Find datasets by name with list_datasets and confirm their columns with
  get_dataset_info. Operators already maintain datasets with names like
  `rastro_ultima_posicao` and `rastro_telemetria`; treat those names as examples to
  search for, not as column contracts. Which operator datasets exist in a given install
  is not verified; confirm by discovery.
- Datasets whose names contain `probe`, `scratch`, or `DELETE_ME` are test artifacts;
  ignore them.
- Datasets cannot be deleted through chat; throwaway artifacts must be removed in the
  Superset UI by a human.

## Native ingest tables

When the native ingest service is enabled, the `rastro` schema also contains the tables
defined in `deploy/postgres/init/02-native.sql`: `raw_envelopes`, `packet_seen`,
`gateway_status`, `node_info`, `chat_messages`, `chat_outbox`, `virtual_gateways`,
`boat_devices`, `node_power`, and `alert_state`. These are present in the native schema;
confirm with get_dataset_info before use. Whether native ingest is turned on in any
given install is not verified; confirm by discovery. `alert_state` is covered by the
gc-alerts skill rather than this one, and `chat_outbox` plus `raw_envelopes` are
internal plumbing that should not be charted.

## House rules for charts

1. Label boats with `COALESCE(friendly_name, node_id)`, or with the `nome` column of
   `vw_ultima_posicao`. Never label with the hex id alone.
2. Derive distance and travel from consecutive `positions` rows per node ordered by
   `pos_time`, and break a track into segments whenever the gap between fixes is larger
   than 30 minutes so coverage gaps never count as distance.
3. Prefer one chart with a node filter over one chart per boat; dozens of near-identical
   charts are a maintenance trap.
4. For latest-state questions use `vw_ultima_posicao`, never a hand-written maximum over
   `positions`.
5. Battery and health over time come from `device_telemetry` ordered by `telem_time`.
6. Boats are nodes. Ignore embarcacoes-like tables and `created_by` columns for
   identity; names come from `nodes.friendly_name`.

## Working with the Superset tools

`execute_sql` is normally denied for the service user with the error "Permission denied:
can_execute_sql_query on SQLLab". Do not retry it expecting a different result; fall
back to datasets and charts.

The working path: find the dataset by name with list_datasets, inspect it with
get_dataset_info, and either read results through existing charts with get_chart_data
and get_chart_preview, or build new ones with create_virtual_dataset, generate_chart,
and update_chart. Compose dashboards with list_dashboards, generate_dashboard, and
add_chart_to_existing_dashboard, hand users explore links with generate_explore_link,
and run health_check first whenever Superset seems unresponsive.
EOF
}

# gc_degraded <area> <reason>: the one place that prints the marker. Chat still starts.
gc_degraded() {
  echo "GC_PROVISION_DEGRADED: $1: $2. Remediation: check GC_SKILLS_ENABLED, GC_SKILL_* and GC_SKILLS_DB_* on the api app, read the api logs for librechat-boot, then redeploy." >&2
}

gc_flag_ok() {
  case "$2" in
    0|1) return 0 ;;
    *) gc_degraded flags "$1 must be 0 or 1"; return 1 ;;
  esac
}

gc_hint_ok() {
  if [ -z "$2" ]; then return 0; fi
  if printf '%s' "$2" | grep -Eq '^[A-Za-z0-9 _.-]{1,64}$'; then return 0; fi
  gc_degraded hints "$1 may contain only letters, digits, space, dot, underscore and hyphen (max 64)"
  return 1
}

# Opt-in by absence: GC_SKILLS_ENABLED unset means off. Domain defaults apply only
# when the master flag is 1. Resolved values are exported for the seeder.
gc_resolve_flags() {
  GC_MASTER=${GC_SKILLS_ENABLED:-0}
  gc_flag_ok GC_SKILLS_ENABLED "$GC_MASTER" || return 1
  if [ "$GC_MASTER" = 1 ]; then
    GC_SKILL_MAPEO=${GC_SKILL_MAPEO:-1}
    GC_SKILL_ALERTS=${GC_SKILL_ALERTS:-1}
    GC_SKILL_KOBO=${GC_SKILL_KOBO:-0}
    GC_SKILL_RASTRO=${GC_SKILL_RASTRO:-0}
  else
    GC_SKILL_MAPEO=0
    GC_SKILL_ALERTS=0
    GC_SKILL_KOBO=0
    GC_SKILL_RASTRO=0
  fi
  gc_flag_ok GC_SKILL_MAPEO "$GC_SKILL_MAPEO" || return 1
  gc_flag_ok GC_SKILL_ALERTS "$GC_SKILL_ALERTS" || return 1
  gc_flag_ok GC_SKILL_KOBO "$GC_SKILL_KOBO" || return 1
  gc_flag_ok GC_SKILL_RASTRO "$GC_SKILL_RASTRO" || return 1
  gc_hint_ok GC_SKILLS_DB_WAREHOUSE "${GC_SKILLS_DB_WAREHOUSE:-}" || return 1
  gc_hint_ok GC_SKILLS_DB_RASTRO "${GC_SKILLS_DB_RASTRO:-}" || return 1
  export GC_MASTER GC_SKILL_MAPEO GC_SKILL_ALERTS GC_SKILL_KOBO GC_SKILL_RASTRO
  return 0
}

# gc-install is generated here from the operator hints. The hints were checked above.
gc_stage_gc_install() {
  mkdir -p "$GC_STAGE/gc-install" || return 1
  {
    printf '%s\n' '---' 'name: gc-install' 'description: Connection names and enabled GC skill families for this LibreChat install. Configured hints only; confirm each name with list_databases before use.' '---' ''
    printf '%s\n' '# This install: configured hints (unverified)' ''
    printf '%s\n' 'These names were typed by the operator when the app was configured. They are not verified. Confirm them with list_databases and list_datasets before you rely on them. Dataset ids are not stored here because they differ per install.' ''
    printf '%s\n' "- Warehouse connection name: ${GC_SKILLS_DB_WAREHOUSE:-not set}"
    printf '%s\n' "- Rastro connection name: ${GC_SKILLS_DB_RASTRO:-not set}" ''
    printf '%s\n' '## Enabled skill families' ''
    printf '%s\n' '- gc-core (always on while provisioning is on)'
    if [ "$GC_SKILL_MAPEO" = 1 ]; then printf '%s\n' '- gc-mapeo'; fi
    if [ "$GC_SKILL_ALERTS" = 1 ]; then printf '%s\n' '- gc-alerts'; fi
    if [ "$GC_SKILL_KOBO" = 1 ]; then printf '%s\n' '- gc-kobo'; fi
    if [ "$GC_SKILL_RASTRO" = 1 ]; then printf '%s\n' '- gc-rastro'; fi
  } > "$GC_STAGE/gc-install/SKILL.md" || return 1
  [ -s "$GC_STAGE/gc-install/SKILL.md" ] || return 1
  return 0
}

gc_stage_all() {
  rm -rf "$GC_STAGE" || return 1
  mkdir -p "$GC_STAGE" || return 1
  if [ "$GC_MASTER" != 1 ]; then return 0; fi
  gc_stage_gc_core || return 1
  gc_stage_gc_install || return 1
  if [ "$GC_SKILL_MAPEO" = 1 ]; then gc_stage_gc_mapeo || return 1; fi
  if [ "$GC_SKILL_ALERTS" = 1 ]; then gc_stage_gc_alerts || return 1; fi
  if [ "$GC_SKILL_KOBO" = 1 ]; then gc_stage_gc_kobo || return 1; fi
  if [ "$GC_SKILL_RASTRO" = 1 ]; then gc_stage_gc_rastro || return 1; fi
  return 0
}

gc_write_seeder() {
  mkdir -p "$GC_SEED_DIR/prompts" || return 1
  cat > "$GC_SEED_DIR/gc_seed.cjs" <<'EOF' || return 1
'use strict';
// GC boot seeder for LibreChat v0.8.8 (spec: task_plan.md "Seeder must-dos").
// Canonical source. Embedded byte-equal into the one-click boot script by
// scripts/gc_skills_bundle.sh through a quoted heredoc, so this file must not
// contain the dollar sign followed by a dollar sign, backticks, or template
// literals. Runs before the server starts and always exits 0: every failure is
// logged as GC_PROVISION_DEGRADED and chat still starts.
//
// Modes (argv[2]):
//   validate-skills <dir>  check each child SKILL.md with LibreChat's validators
//   seed                   reconcile prompt groups and public ACLs with the env flags

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const MARK = 'GC_PROVISION_DEGRADED';
const DEADLINE_MS = 150000;
const CONNECT_BUDGET_MS = 90000;
const STATE_DIR = '/app/skills/.gc-state';
const STATE_FILE = path.join(STATE_DIR, 'seed.json');
const PROMPTS_DIR = '/app/gc-seed/prompts';
const VIEWER_ROLE_ID = 'promptGroup_viewer';
const OWNER_ROLE_ID = 'promptGroup_owner';
const OWNER_ROLE_NAME = 'com_ui_role_owner';
const OWNER_ROLE_DESC = 'com_ui_role_owner_desc';
const AUTHOR_NAME = 'Guardian Connector';
const MANAGED_PREFIX = 'gc-prompt:';

function degraded(area, reason) {
  console.error(MARK + ': ' + area + ': ' + reason + '. Remediation: check GC_SKILLS_* settings and the api logs for "librechat-boot", then redeploy.');
}

function hexId(seed) {
  return crypto.createHash('sha1').update(seed).digest('hex').slice(0, 24);
}

// Synthetic author. No User row is created, so LibreChat's first-user admin
// bootstrap (countUsers() === 0) stays intact. See docs/librechat-integrations.md.
const AUTHOR_HEX = hexId('gc-service:author');
const ROLE_NAME = 'com_ui_role_viewer';
const ROLE_DESC = 'com_ui_role_viewer_desc';

process.on('unhandledRejection', function (err) {
  degraded('seeder', 'unhandled rejection: ' + (err && err.message ? err.message : String(err)));
  process.exit(0);
});
process.on('uncaughtException', function (err) {
  degraded('seeder', 'uncaught exception: ' + (err && err.message ? err.message : String(err)));
  process.exit(0);
});

// Wall-clock deadline armed before any connection attempt.
setTimeout(function () {
  degraded('seeder', 'wall-clock deadline of ' + DEADLINE_MS + ' ms reached');
  process.exit(0);
}, DEADLINE_MS).unref();

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

// ---------- starter prompt files -------------------------------------------

// Format: H1 title line, then "## <title>" sections. Each section body is the prompt.
function parseStarters(family, text) {
  const out = [];
  const lines = text.split(/\r?\n/);
  let title = null;
  let body = [];
  function flush() {
    if (title !== null) {
      const prompt = body.join('\n').trim();
      if (prompt.length > 0) out.push({ family: family, title: title, prompt: prompt });
    }
  }
  for (const line of lines) {
    const m = /^## (.+)$/.exec(line);
    if (m) {
      flush();
      title = m[1].trim();
      body = [];
    } else if (title !== null) {
      body.push(line);
    }
  }
  flush();
  return out;
}

function slugOf(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48);
}

function desiredItems(families) {
  const items = [];
  for (const family of families) {
    const file = path.join(PROMPTS_DIR, family + '.md');
    if (!fs.existsSync(file)) {
      degraded('prompts', 'missing prompt file for ' + family);
      continue;
    }
    for (const starter of parseStarters(family, fs.readFileSync(file, 'utf8'))) {
      if (starter.prompt.length > 2000) {
        degraded('prompts', 'starter too long: ' + family + '/' + starter.title);
        continue;
      }
      const key = family + '/' + slugOf(starter.title);
      const fields = {
        name: starter.title,
        category: family,
        oneliner: 'Guardian Connector starter (' + family + ')',
        prompt: starter.prompt,
      };
      items.push({
        key: key,
        groupId: hexId(MANAGED_PREFIX + key + ':group'),
        promptId: hexId(MANAGED_PREFIX + key + ':prompt'),
        aclId: hexId(MANAGED_PREFIX + key + ':acl'),
        ownerAclId: hexId(MANAGED_PREFIX + key + ':owner-acl'),
        fields: fields,
        hash: sha256(JSON.stringify(fields)),
      });
    }
  }
  return items;
}

function readState() {
  try {
    const parsed = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    if (parsed && parsed.version === 1 && parsed.items) return parsed;
    degraded('state', 'unrecognized seed state file; ignoring it');
    return null;
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    degraded('state', 'cannot read seed state: ' + err.message);
    return null;
  }
}

function writeState(state) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const tmp = STATE_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, STATE_FILE);
}

// ---------- validate-skills ------------------------------------------------

function validateSkills(dir) {
  const dsc = require('@librechat/data-schemas');
  let failed = false;
  const names = fs.readdirSync(dir, { withFileTypes: true }).filter(function (e) { return e.isDirectory(); }).map(function (e) { return e.name; });
  for (const name of names) {
    const file = path.join(dir, name, 'SKILL.md');
    if (!fs.existsSync(file)) continue;
    const content = fs.readFileSync(file, 'utf8');
    const fm = /^---\n([\s\S]*?)\n---/.exec(content);
    if (!fm) { degraded('skills', name + ': missing frontmatter'); failed = true; continue; }
    const nameLine = /^name: *(.+)$/m.exec(fm[1]);
    const descLine = /^description: *(.+)$/m.exec(fm[1]);
    const skillName = nameLine ? nameLine[1].trim() : '';
    const description = descLine ? descLine[1].trim() : '';
    const issues = [].concat(
      dsc.validateSkillName(skillName),
      dsc.validateSkillDescription(description),
      dsc.validateSkillBody(content)
    );
    const parts = dsc.partitionIssues(issues);
    if (skillName !== name) { degraded('skills', name + ': frontmatter name does not match folder'); failed = true; }
    if (parts.errors.length > 0) {
      degraded('skills', name + ': ' + parts.errors.map(function (i) { return i.field + ' ' + i.message; }).join('; '));
      failed = true;
    }
  }
  return failed ? 1 : 0;
}

// ---------- seed -----------------------------------------------------------

function families(env) {
  const list = [];
  if (env.GC_SKILLS_ENABLED !== '1') return list;
  list.push('gc-core');
  if (env.GC_SKILL_MAPEO === '1') list.push('gc-mapeo');
  if (env.GC_SKILL_ALERTS === '1') list.push('gc-alerts');
  if (env.GC_SKILL_KOBO === '1') list.push('gc-kobo');
  if (env.GC_SKILL_RASTRO === '1') list.push('gc-rastro');
  return list;
}

async function connect(uri) {
  const mongoose = require('mongoose');
  const started = Date.now();
  let delay = 1000;
  for (;;) {
    try {
      await mongoose.connect(uri, { serverSelectionTimeoutMS: 5000, maxPoolSize: 2 });
      return mongoose;
    } catch (err) {
      if (Date.now() - started + delay > CONNECT_BUDGET_MS) throw new Error('mongo unreachable within budget: ' + err.message);
      await new Promise(function (r) { setTimeout(r, delay); });
      delay = Math.min(delay * 2, 10000);
    }
  }
}

// Ensures the viewer and owner roles (same shape as LibreChat seedDefaultRoles).
async function ensureRole(models, accessRoleId, name, description, permBits) {
  await models.AccessRole.updateOne(
    { accessRoleId: accessRoleId },
    { $setOnInsert: { accessRoleId: accessRoleId, name: name, description: description, resourceType: 'promptGroup', permBits: permBits } },
    { upsert: true }
  );
  const role = await models.AccessRole.findOne({ accessRoleId: accessRoleId }).lean();
  return role ? role._id : null;
}

async function ensureRoles(models) {
  const viewer = await ensureRole(models, VIEWER_ROLE_ID, ROLE_NAME, ROLE_DESC, 1);
  const owner = await ensureRole(models, OWNER_ROLE_ID, OWNER_ROLE_NAME, OWNER_ROLE_DESC, 15);
  return { viewer: viewer, owner: owner };
}

async function dbHashOf(models, groupId) {
  const group = await models.PromptGroup.findById(groupId).lean();
  if (!group) return { group: null, hash: null };
  const prompt = await models.Prompt.findById(group.productionId).lean();
  const fields = {
    name: group.name,
    category: group.category,
    oneliner: group.oneliner,
    prompt: prompt ? prompt.prompt : null,
  };
  return { group: group, hash: sha256(JSON.stringify(fields)) };
}

async function upsertContent(models, item) {
  await models.Prompt.updateOne(
    { _id: item.promptId },
    { $set: { prompt: item.fields.prompt, type: 'text', groupId: item.groupId, author: AUTHOR_HEX } },
    { upsert: true }
  );
  await models.PromptGroup.updateOne(
    { _id: item.groupId },
    {
      $set: {
        name: item.fields.name,
        category: item.fields.category,
        oneliner: item.fields.oneliner,
        productionId: item.promptId,
      },
      $setOnInsert: { author: AUTHOR_HEX, authorName: AUTHOR_NAME, numberOfGenerations: 0 },
    },
    { upsert: true }
  );
}

async function ensurePublicAcl(models, item, roleObjId, report) {
  const existing = await models.AclEntry.findOne({ resourceType: 'promptGroup', resourceId: item.groupId, principalType: 'public' }).lean();
  if (existing) {
    if (roleObjId && String(existing.roleId) !== String(roleObjId)) {
      report.conflicts.push(item.key + ': public ACL role changed by an operator; kept');
    }
    return;
  }
  await models.AclEntry.updateOne(
    { _id: item.aclId },
    {
      $setOnInsert: {
        resourceType: 'promptGroup',
        resourceId: item.groupId,
        principalType: 'public',
        roleId: roleObjId,
        permBits: 1,
        grantedBy: AUTHOR_HEX,
        grantedAt: new Date(),
      },
    },
    { upsert: true }
  );
}

// Revokes every ACL on the group: the public viewer row and the synthetic owner row.
async function revokeItem(models, groupId) {
  await models.AclEntry.deleteMany({ resourceType: 'promptGroup', resourceId: groupId });
}

// Owner row for the synthetic author, so owner-scoped checks resolve.
async function ensureOwnerAcl(models, item, ownerRoleObjId) {
  if (!ownerRoleObjId) return;
  await models.AclEntry.updateOne(
    { _id: item.ownerAclId },
    {
      $setOnInsert: {
        resourceType: 'promptGroup',
        resourceId: item.groupId,
        principalType: 'user',
        principalId: AUTHOR_HEX,
        principalModel: 'User',
        roleId: ownerRoleObjId,
        permBits: 15,
        grantedBy: AUTHOR_HEX,
        grantedAt: new Date(),
      },
    },
    { upsert: true }
  );
}

// Removes only the managed prompt. A group that holds other versions is kept
// (operator drafts stay) and only loses its public ACL.
async function removeItem(models, item, report) {
  await revokeItem(models, item.groupId);
  const others = await models.Prompt.countDocuments({ groupId: item.groupId, _id: { $ne: item.promptId } });
  if (others > 0) {
    report.conflicts.push(item.groupId + ': holds operator versions; only the managed version was left in place, public access revoked');
    return false;
  }
  await models.Prompt.deleteOne({ _id: item.promptId });
  await models.PromptGroup.deleteOne({ _id: item.groupId });
  return true;
}

async function seed(env) {
  const enabled = env.GC_SKILLS_ENABLED === '1';
  const state = readState();
  if (!enabled && !state) {
    console.log('gc-seed: GC_SKILLS_ENABLED is off and nothing is managed; nothing to do');
    return 0;
  }
  const uri = env.MONGO_URI;
  if (!uri) { degraded('seeder', 'MONGO_URI is not set'); return 0; }

  const wanted = desiredItems(families(env));
  const managed = state ? state.items : {};
  const report = { conflicts: [], created: 0, updated: 0, removed: 0 };

  const mongoose = await connect(uri);
  try {
    const models = require('@librechat/data-schemas').createModels(mongoose);
    const roles = await ensureRoles(models);
    const roleObjId = roles.viewer;
    const next = {};
    const wantedKeys = {};
    for (const item of wanted) wantedKeys[item.key] = true;

    // Disable path: managed items no longer wanted.
    for (const key of Object.keys(managed)) {
      if (wantedKeys[key]) continue;
      const old = managed[key];
      const current = await dbHashOf(models, old.groupId);
      if (current.group === null) continue;
      if (current.hash === old.hash) {
        if (await removeItem(models, old, report)) report.removed++;
      } else {
        await revokeItem(models, old.groupId);
        report.conflicts.push(key + ': edited by an operator; kept private, public access revoked');
      }
    }

    // Reconcile wanted items, then publish ACLs last.
    for (const item of wanted) {
      const current = await dbHashOf(models, item.groupId);
      const previous = managed[item.key];
      if (current.group === null) {
        await upsertContent(models, item);
        next[item.key] = { groupId: item.groupId, promptId: item.promptId, hash: item.hash };
        report.created++;
      } else if (current.hash === item.hash) {
        next[item.key] = { groupId: item.groupId, promptId: item.promptId, hash: item.hash };
      } else if (previous && current.hash === previous.hash) {
        await upsertContent(models, item);
        next[item.key] = { groupId: item.groupId, promptId: item.promptId, hash: item.hash };
        report.updated++;
      } else if (previous) {
        report.conflicts.push(item.key + ': edited by an operator; desired content not applied');
        next[item.key] = { groupId: item.groupId, promptId: item.promptId, hash: previous.hash };
      } else {
        // Existing content this seeder never wrote: leave it alone and do not adopt it.
        report.conflicts.push(item.key + ': exists but was not created by GC seeding; left unmanaged');
      }
    }

    // Ledger first: ACLs are published only after the managed state is durable,
    // so a later disable can always find and revoke what was published.
    writeState({ version: 1, items: enabled ? next : {} });

    if (roleObjId) {
      for (const item of wanted) {
        if (next[item.key]) {
          await ensurePublicAcl(models, item, roleObjId, report);
          await ensureOwnerAcl(models, item, roles.owner);
        }
      }
    } else {
      degraded('acl', 'viewer role missing; prompts are not public until the next boot');
    }
    console.log('gc-seed: created=' + report.created + ' updated=' + report.updated + ' removed=' + report.removed + ' conflicts=' + report.conflicts.length);
    for (const c of report.conflicts) console.error(MARK + ': prompts: ' + c + '. Remediation: export your edit, then delete the managed prompt in the UI or set GC_SKILLS_ENABLED=0.');
  } finally {
    await mongoose.disconnect().catch(function () {});
  }
  return 0;
}

async function main() {
  const mode = process.argv[2];
  if (mode === 'validate-skills') {
    return validateSkills(process.argv[3]);
  }
  if (mode === 'seed') {
    return seed(process.env);
  }
  degraded('seeder', 'unknown mode ' + String(mode));
  return 0;
}

main().then(function (code) {
  process.exit(code);
}, function (err) {
  degraded('seeder', err && err.message ? err.message : String(err));
  process.exit(process.argv[2] === 'validate-skills' ? 1 : 0);
});
EOF
  cat > "$GC_SEED_DIR/prompts/gc-core.md" <<'EOF' || return 1
# Guardian Connector starter prompts

## See what data this install has

Show me what data this Guardian Connector install contains. Call list_databases first, then list_datasets, and group the dataset names by database. Ignore anything whose name contains probe, scratch, or DELETE_ME, since those are test artifacts. For each group, give a one-line description of the kind of data it holds based on the names, and tell me which names you are unsure about instead of guessing.

## Understand a dataset before charting

Before we build anything, help me understand one dataset. Find the dataset I ask about by name with list_datasets, because dataset ids differ per install, then call get_dataset_info or get_schema and list the actual column names. Point out which columns are ingestion metadata, such as underscore-prefixed Kobo or ODK fields, and which are real measures, categories, or timestamps. Give me the row count if the dataset info includes one.

## Build one clean chart

Build a single chart of counts per category from the observations data. Verify the exact dataset name with list_datasets and the exact column names with get_dataset_info before you write anything, and leave out metadata columns. Prefer one chart with a filter over several near-identical charts. In your answer, name the dataset and the columns the chart uses, and report the row count behind each number you give me.

## Summarize without exposing locations

Summarize activity in this data without exposing anyone's exact location. Aggregate by time period or named area instead of plotting raw latitude and longitude, and keep coordinates off any dashboard. First check the schema and warn me if the dataset contains coordinate columns or if anything I have asked for in this thread would publish exact positions of people, boats, or territories. Report row counts and the dataset name for every figure.

## Faithful export with metadata intact

I need a faithful table export of a dataset: keep every column exactly as stored, including underscore-prefixed Kobo and ODK fields, Mapeo fields that start with a dollar sign, and the Frizzle topic column. Do not drop or rename anything silently. Resolve the dataset by name with list_datasets, confirm the columns with get_dataset_info, then build the table and list the columns you kept, the dataset name, and the row count.
EOF
  cat > "$GC_SEED_DIR/prompts/gc-mapeo.md" <<'EOF' || return 1
# Starter prompts for gc-mapeo

## Monthly observation trend

Using the warehouse dataset comapeo_evu_observations, build a chart of observations per month. Exclude rows where deleted is true, filter to the project I name in a follow-up message, and use created_at as the time axis. State the project filter and the time axis in the chart title, then add the chart to a dashboard called Mapeo field activity.

## Observations by category

Show me the count of non-deleted CoMapeo observations grouped by category from the comapeo_evu_observations dataset. Label each result with the human-readable category name, not the raw category_id, and sort from most to least common. If one category dominates, note that in a single sentence.

## Photo evidence coverage

From comapeo_evu_observations, tell me what share of observations carry attachments, meaning photos. Exclude deleted rows, group by category, and label with the category name. Build a chart I can add to the existing field dashboard, and verify the numbers with get_chart_data before showing them to me.

## Check the coordinate order

Pick one row from comapeo_evu_observations that is not deleted and show me its g__type and g__coordinates values. I want to confirm the coordinate order is longitude first and latitude second before we build any map. Also tell me that row's category, project_name, and created_at so I can sanity-check it.

## Patrol tracks check

Check whether a dataset named comapeo_evu_tracks exists using list_datasets, and if it does, call get_dataset_info on it and list its columns. Do not build any chart yet; first tell me what a patrol track row contains and how it differs from an observation row. Remember these are patrol tracks, not mesh or rastro tracks.
EOF
  cat > "$GC_SEED_DIR/prompts/gc-alerts.md" <<'EOF' || return 1
# gc-alerts starter prompts

## What is alerting right now?

Show me every alert currently active in the rastro database. For each one give the alert kind, the node label, or the gateway identifier when node_num is empty, plus when the condition was first raised and how long it has been active. Leave out cleared episodes and retired kinds. If direct SQL is not allowed for your user, build the answer as a dataset and a table chart instead.

## How often have gateways gone silent?

Count gateway_mudo episodes over the last 30 days from the alert_state table, one row per episode, using the since column for timing. Group them by day or week so I can see whether silences are becoming more frequent. In the answer, remind me that this counts episodes of the alert condition, not individual lost uplinks.

## Which fixed nodes have critical batteries?

List bateria_critica alerts raised in the past week, active or cleared, with the node label from COALESCE(friendly_name, node_id), when each episode started, and whether it is still open. This kind only applies to fixed nodes as configured by the operator, so tell me if anything about the fixed versus mobile split needs the operator's node list to answer fully.

## Build an alerts dashboard

Make a Guardian Connector alerts dashboard in Superset: one table chart of active alerts showing kind, node label, and time active, and one time bar chart of episodes per week by kind. Use a virtual dataset over alert_state with cleared_at null for the first chart. If a similarly named dashboard already exists, add the charts to it instead of creating a duplicate, and give me the explore link.

## What does last_notified actually prove?

For the currently active alerts, show the last_notified timestamps and explain what that column does and does not mean: it records that a notification attempt was logged, not that a push or email was delivered. Point out any alert that has been active for a long time with no recorded notification attempt.
EOF
  cat > "$GC_SEED_DIR/prompts/gc-kobo.md" <<'EOF' || return 1
# gc-kobo starter prompts

## Submission overview

Using the Superset MCP tools, find the dataset `checklist_missao_evu` in the Warehouse database and show me how many submissions were recorded per month based on `_submission_time`, broken down by team using `EQUIPE_S_DA_MISS_O`. Ignore any dataset whose name contains probe, scratch, or DELETE_ME. Choice meanings were not sampled, so chart the distinct team values first and show me the raw values before you summarize anything.

## Supplies audit

From `checklist_missao_evu`, build a dataset chart of the food and fuel quantities for the most recent submissions: `ARROZ_KG`, `FEIJ_O_KG`, `BOLACHA_KG`, `Gasolina`, and `Quantidade_de_Diesel`. Use the base column names; columns with a __group_ suffix duplicate them. Show raw values per submission rather than averages. If execute_sql fails with a Permission denied error on can_execute_sql_query, fall back to datasets and charts.

## Equipment checks

From `checklist_missao_evu`, report the latest values of `Horas_do_motor_250__group_gy0se63__group_lk2wb32`, `Verificar_leo_do_gerador__group_dh9sh33__group_ch9gb66`, and `Voltagem_das_baterias_do_sistema_solar___group_dh9sh33__group_c`, each with its submission time. The last column name is truncated at the identifier limit and must be quoted exactly as written. Find the dataset by name with list_datasets, since dataset ids differ per install.

## Mission locations

Use the virtual dataset `checklist_missao_evu_map` to show where missions started. It derives latitude from the first space-separated part of `Record_your_current_location` and longitude from the second, so latitude comes first. Field-team coordinates are sensitive: show counts and general areas in anything shared beyond the mission coordinators, and ask me before plotting exact points anywhere shared.

## Choice meanings

For `Selecione_se_esta_iniciando_ou` and `Qual_checklist_voc_vai_realizar` in `checklist_missao_evu`, chart the distinct values with counts. The side tables `checklist_missao_evu__columns` and `checklist_missao_evu__labels` are reported to hold column metadata and choice labels but are not registered as Superset datasets, so they could not be verified; if you can read labels from them use the labels, otherwise show the raw values and say the meanings are not confirmed.
EOF
  cat > "$GC_SEED_DIR/prompts/gc-rastro.md" <<'EOF' || return 1
# gc-rastro starter prompts

Paste any of these into chat to start a Rastro analytics task.

## Latest position of every boat

Using the rastro database, build one chart showing the latest position and battery level of every boat. Find the dataset by name with list_datasets; operators keep one named rastro_ultima_posicao, but confirm its columns with get_dataset_info before relying on them. If no such dataset exists, create a virtual dataset over the vw_ultima_posicao view instead of hand-picking maximums from positions. Label each boat with its resolved name column, never the raw hex node id.

## Distance traveled per boat

Create one chart of distance traveled per boat for a date range I will give you. Derive the distance from consecutive rows of the positions dataset per node, ordered by the fix timestamp, and split each boat's track into segments whenever two fixes are more than 30 minutes apart so coverage gaps never count as travel. Keep it as a single chart with a boat filter rather than one chart per boat, and label boats with COALESCE(friendly_name, node_id).

## Battery and device health over time

Show battery level over time for the boats in the rastro mesh. Look for a dataset named rastro_telemetria, or build one over the device_telemetry table, and plot by its telemetry timestamp column. Confirm the actual column names with get_dataset_info before charting. Add voltage as a second series if it is available, and let me filter the chart down to the boats I name.

## Fleet dashboard

Assemble a Superset dashboard for the boat fleet: one latest-state chart from the last-position dataset, one battery-over-time chart, and one distance chart with a date filter. Reuse existing datasets and charts where they exist by searching names with list_datasets and list_charts, and skip anything named probe, scratch, or DELETE_ME. Keep rastro data out of the same chart as warehouse patrol data.

## Which database is this

Before we chart anything, tell me which database we should be working in. List the available databases and datasets, separate the rastro mesh data from the warehouse patrol exports, and summarize what already exists for boats and nodes. Report dataset and database names rather than ids, since ids change per install, and flag anything that looks like a leftover test artifact.
EOF
  [ -s "$GC_SEED_DIR/gc_seed.cjs" ] || return 1
  return 0
}

# Publishes staged skills, one directory per managed name. A manifest of
# name and content hash lets the boot tell managed content from operator edits.
# Only one writer may run at a time: a lock directory, stale after 5 minutes.
gc_reconcile_skills() {
  SK=/app/skills
  ST=$SK/.gc-state
  mkdir -p "$ST" || return 1
  waited=0
  until mkdir "$ST/lock" 2>/dev/null; do
    if [ -n "$(find "$ST/lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then rmdir "$ST/lock" 2>/dev/null; continue; fi
    waited=$((waited + 1))
    if [ "$waited" -gt 60 ]; then gc_degraded skills "another writer holds $ST/lock"; return 1; fi
    sleep 2
  done
  gc_reconcile_locked
  rc=$?
  rmdir "$ST/lock" 2>/dev/null || true
  return $rc
}

gc_reconcile_locked() {
  if ! gc_stage_all; then gc_degraded skills "could not stage skill files"; return 1; fi
  if ! node "$GC_SEED_DIR/gc_seed.cjs" validate-skills "$GC_STAGE"; then
    gc_degraded skills "staged skills failed LibreChat validation; the published copies were left as they were"
    return 1
  fi
  NEWMAN="$ST/manifest.new"
  : > "$NEWMAN" || return 1
  problems=0
  for name in gc-core gc-install gc-mapeo gc-alerts gc-kobo gc-rastro; do
    dst="$SK/$name/SKILL.md"
    prev=$(awk -v n="$name" '$1 == n { print $2 }' "$ST/manifest.txt" 2>/dev/null || true)
    cur=""
    if [ -f "$dst" ]; then cur=$(sha256sum "$dst" | cut -d' ' -f1); fi
    if [ -f "$GC_STAGE/$name/SKILL.md" ]; then
      new=$(sha256sum "$GC_STAGE/$name/SKILL.md" | cut -d' ' -f1)
      if [ -n "$cur" ] && [ "$cur" != "$new" ] && [ "$cur" != "$prev" ]; then
        gc_degraded skills "$name was edited on the volume; kept the operator copy and stopped updating it"
        problems=1
        if [ -n "$prev" ]; then printf '%s %s\n' "$name" "$prev" >> "$NEWMAN"; fi
        continue
      fi
      if [ "$cur" != "$new" ]; then
        if ! mkdir -p "$SK/$name" || ! cp "$GC_STAGE/$name/SKILL.md" "$dst.tmp" || ! mv "$dst.tmp" "$dst"; then
          gc_degraded skills "could not publish $name"
          problems=1
          continue
        fi
      fi
      printf '%s %s\n' "$name" "$new" >> "$NEWMAN"
    elif [ -n "$cur" ] && [ -n "$prev" ]; then
      if [ "$cur" = "$prev" ]; then
        # Remove only the managed file; the directory goes only if nothing else is in it.
        rm -f "$SK/$name/SKILL.md" || problems=1
        rmdir "$SK/$name" 2>/dev/null || gc_degraded skills "$name still holds operator files; only SKILL.md was removed"
      else
        gc_degraded skills "$name was edited on the volume; kept it and stopped managing it"
        problems=1
      fi
    fi
  done
  mv "$NEWMAN" "$ST/manifest.txt" || return 1
  return $problems
}

# Entry point. Always invoked as "gc_main || true" by the boot script.
gc_main() {
  if ! gc_resolve_flags; then
    gc_degraded flags "invalid GC settings; provisioning is disabled for this boot"
    return 0
  fi
  if ! mkdir -p /app/skills; then gc_degraded skills "cannot create /app/skills"; return 0; fi
  if ! gc_write_seeder; then gc_degraded seeder "cannot write the seeder"; return 0; fi
  if ! gc_reconcile_skills; then gc_degraded skills "skills reconciliation reported problems"; fi
  if ! node --max-old-space-size=192 "$GC_SEED_DIR/gc_seed.cjs" seed; then
    gc_degraded seeder "the seed process failed"
  fi
  return 0
}
# END GC PAYLOAD
gc_main || true

# ---------- run ---------------------------------------------------------------
exec node server/index.js
