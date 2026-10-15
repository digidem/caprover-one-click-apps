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
