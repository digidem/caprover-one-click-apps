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
