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
