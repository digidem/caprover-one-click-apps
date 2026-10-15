# GC Analytics agent: manual recipe for the LibreChat UI

This recipe creates a "GC Analytics" agent by hand in the LibreChat web interface of a Guardian Connector install. Automatic agent seeding is deferred to a later version, so this manual path is the supported route in version 1. An operator who can read the app settings and log in to LibreChat can follow it in a few minutes.

## 1. Before you start

Collect three things from the install before you open the UI.

- The LibreChat app settings. You need the value of `LLM_NAME`, which names the custom endpoint the agent will use as its provider. The default is "Tinfoil". You also need `LLM_DEFAULT_MODEL`, the model the agent should use; it is gpt-oss-120b unless the operator changed it. The full set of models the endpoint serves is `LLM_MODELS`.
- Whether `LLM_API_KEY` is set on the app. If it is empty, each user enters their own key in the LibreChat UI before the agent can answer them. If it is set, all users share that one key and share its spend, so one heavy user consumes the budget available to everyone. Work out which case applies to this install before you show the agent to other people, because it decides both who pays for the agent and whether a user without a key can use it at all.
- Whether `SUPERSET_MCP_URL` is set on the api app. The Superset MCP server appears in the agent's tools only when that variable is set. If it is not set, the recipe still works, but the agent has no Superset tools, and the acceptance check passes without a `list_databases` call.

## 2. Create the agent

Open LibreChat and go to the agent builder from the sidebar; the label may differ in your version. Create a new agent and fill in the fields as follows. The builder may group or word these fields slightly differently; the label may differ in your version.

| Field | Value |
| --- | --- |
| Name | GC Analytics |
| Provider | The exact value of `LLM_NAME` from the app settings. With the default install this is "Tinfoil". |
| Model | The exact value of `LLM_DEFAULT_MODEL`, which is gpt-oss-120b by default. It must be one of the models in `LLM_MODELS`. |
| Tools | Enable the server named "superset" if it is listed. It appears only when `SUPERSET_MCP_URL` is set on the api app. |
| Skills | Enable gc-core, plus each of gc-mapeo, gc-alerts, gc-kobo, gc-rastro whose flag is set to 1 (see below). |
| Instructions | Paste the block from section 3. |
| Sharing | Leave the agent private to you. |

Three fields need more care than the table shows.

Provider. Type the endpoint name exactly as `LLM_NAME` spells it, including spaces and capitals. The agent's provider must equal that endpoint name exactly; anything else gives no model choice, and the agent cannot be completed. If the install uses the default, the value is "Tinfoil", not "tinfoil" and not "Tinfoil " with a trailing space.

Model. Pick a model the endpoint actually serves. The safe choice is `LLM_DEFAULT_MODEL`, which is gpt-oss-120b unless the operator changed it. Any other choice must come from `LLM_MODELS`, the operator's model list; a model outside that list will fail at chat time.

Tools. The Superset MCP server's name in LibreChat is "superset". Its tools run with the permissions of the Superset process that serves them, so the agent's queries follow the RBAC of that process, not the role of the person chatting. Tell every prospective user this: an operation succeeds only if the serving Superset process's role allows it, and write tools need the matching Superset role. An agent asked to create or change dashboards is refused until that role is in place.

Skills. The install's skills appear in the skills picker only when `GC_SKILLS_ENABLED` is 1. gc-core is always present. gc-mapeo, gc-alerts, gc-kobo, and gc-rastro appear when their `GC_SKILL_*` flag is 1, so the picker holds exactly the skills the install enables. A skill named gc-install lists the connection hints for the install; those hints are not verified, so treat them as leads to check rather than confirmed settings.

Sharing. An agent created in the UI is private to its author unless it is shared. Sharing it with all users is a separate step, and this recipe does not depend on it: the agent works for you as soon as you save it.

## 3. Instructions text

Paste this block into the Instructions field, replacing any default text.

```text
You are GC Analytics, an assistant for exploring Guardian Connector data. Find datasets by name first: list which datasets exist and match by name before you query anything. Never guess dataset ids, column names, or other identifiers; look them up with your tools, or ask the user. Keep metadata out of charts unless asked: a chart shows the data itself, not dataset descriptions or notes. Aggregate instead of exposing exact locations; prefer counts, sums, and grouped summaries over individual rows or precise coordinates. With every number you report, state the row count behind it and the name of the dataset it came from. If a tool call returns an error, quote the error message exactly and stop; do not retry with guessed values and do not continue on partial data.
```

The block is under 900 characters. The order of the rules matters: discovery comes before any query, and a tool error stops the agent instead of sending it into guessed retries.

## 4. Acceptance check

Open a new chat, select the GC Analytics agent, and send one short message: "List the databases you can see."

A pass looks like this. The reply arrives, and it is written by the configured model, gpt-oss-120b by default. When `SUPERSET_MCP_URL` is set, the agent calls `list_databases` through the Superset tools and answers with the databases the serving Superset process can see. When the Superset server is not configured, a pass is a plain reply from the model saying it has no Superset tools available.

If the reply does not arrive at all, check the model name and the provider name first; those two fields cause almost every silent failure. Section 5 lists the fixes.

## 5. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| No provider in the list | The provider value does not equal `LLM_NAME` exactly. Retype it, including spaces and capitals; the default is "Tinfoil". Anything else gives no model choice. |
| No tools shown | `SUPERSET_MCP_URL` is not set on the api app, so the Superset MCP server is not mounted. Set the variable, update the app, and reopen the agent's tool list. |
| Skills missing | `GC_SKILLS_ENABLED` is not 1 on the app, so the skills picker is empty. Individual skills also need their own flag set to 1: gc-mapeo, gc-alerts, gc-kobo, and gc-rastro appear only when their `GC_SKILL_*` flag is 1. |
| Superset permission denied | Quote the error exactly; it names the permission that failed. The tools use the RBAC of the Superset process that serves them, so the fix is on the Superset side: grant the matching Superset role the operation needs. Write tools need the matching role in particular. |
| Reply never arrives | Check the model name and the provider name first. The model must be in `LLM_MODELS`, and the provider must equal `LLM_NAME` exactly. Also confirm the key situation: with an empty `LLM_API_KEY`, your own user must hold a key before any reply can come back. |

## 6. What is not automated yet

Two parts of this recipe are manual because automation is deferred to a later version.

- Agent seeding. The GC Analytics agent is not created automatically when the app installs or updates. Every operator who wants the agent follows sections 2 to 4 by hand. A later version will seed the agent with these fields and instructions on install.
- Sharing with all users. The recipe leaves the agent private to its author. Making it available to every user of the install is a separate sharing step in the UI, done per agent after creation, and nothing in the current version automates it.
