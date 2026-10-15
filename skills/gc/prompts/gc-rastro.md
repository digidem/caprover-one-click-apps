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
