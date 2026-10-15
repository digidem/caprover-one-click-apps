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
