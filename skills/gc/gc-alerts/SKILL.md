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
