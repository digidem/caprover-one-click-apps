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
