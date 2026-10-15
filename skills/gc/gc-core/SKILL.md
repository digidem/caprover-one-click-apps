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
