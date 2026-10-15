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
