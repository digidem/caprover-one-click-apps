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
