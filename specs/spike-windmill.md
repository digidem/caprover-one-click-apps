# Spike 6.6: Windmill scopes and folder enforcement (evidence)

Date: 2026-10-09. Local only: Windmill CE 1.830.0 (latest release) with postgres:16 on a private network, bound to 127.0.0.1. Workspace `main`, non-admin user `librechat-agent`. Folder `f/agent` (user writer), `f/other` (admin only). Containers, network and volume removed afterwards.

## Scope strings
- API domains (`GET /api/tokens/list/scopes`): `scripts:read[path]`, `scripts:write[path]`, `flows:read[path]`, `flows:write[path]`, `jobs:read[path]`, `jobs:write`, `jobs:cancel[path]`, `jobs:run:scripts[path]`, `jobs:run:flows[path]`, `schedules:read[path]`, `schedules:write[path]`.
- `jobs:run` alone is NOT a valid domain. Use `jobs:run:scripts` or `jobs:run:flows`.
- Token creation returns 201 for any string. Typos are not rejected.
- The MCP endpoint ignores API domain scopes: `scripts:write:f/agent/*` gives 403 `Required scope: mcp:*`.

## MCP scopes (from Windmill source at v1.830.0)
- Endpoint tools: `mcp:endpoints:<name>,<name>,...`
- Path-confined: `mcp:scripts:f/agent/*`, `mcp:flows:f/agent/*`
- Legacy: `mcp:all`, `mcp:favorites`, `mcp:all:<folder>`
- Working token: `mcp:endpoints:listScripts,getScriptByPath,createScript,updateScript,runScriptByPath,deleteScriptByPath,listSchedules,getSchedule,createSchedule,updateSchedule,listJobs,getJobLogs,getJob` plus `mcp:scripts:f/agent/*` and `mcp:flows:f/agent/*`. Lists 14 tools.
- Tool exposure follows the endpoint scope: `mcp:endpoints:createScript` alone lists only `createScript`.

## Folder enforcement (as librechat-agent)
| Call | Result |
|---|---|
| createScript f/agent/x | OK |
| createScript f/other/y | REJECTED: not in token scope |
| updateScript f/agent/x | OK |
| runScriptByPath f/agent/x | OK |
| runScriptByPath f/other/x | REJECTED |
| getScriptByPath f/other/x | REJECTED |
| createSchedule f/agent/sched1 (cron `0 0 12 * * *`, Europe/Lisbon) | OK |
| createSchedule f/other/sched1 | REJECTED with HTTP 500 (RLS error, not a scope error) |
| createSchedule f/agent/sched2 with script_path f/other/x | ACCEPTED: GAP |
| deleteScriptByPath f/agent/x | REJECTED: admin only |
| getJobLogs | OK |

Admin control: runScriptByPath f/other/x works.

## Gotchas
- Scripts created via API have lock NULL for a few seconds. Run-by-path returns 404 in that window. Tests must poll.
- `deno` scripts fail in the CE image (`Deno not found`). Use `bun`.
- Creating a script at an existing path returns a "Path conflict" error (exact text not recorded in the spike).
- Non-admin `deleteScriptByPath`: 403 `Require Admin privileges`.
- Token creation does not catch scope typos (any string gets 201).

## Consequence
The schedule gap breaks D11's folder rule, so the dedicated workspace is the default. A folder token without schedule tools would avoid it.
