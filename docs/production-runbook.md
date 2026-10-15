# Production deployment plan — Superset MCP integration

Target: CapRover app `librechat` from `public/v4/apps/librechat.yml`, published
through the GitHub Pages registry (`master` -> `deploy.yml` -> `gh-pages`).
Scope: the Superset MCP integration (sections 1 and 1.11 of
`docs/librechat-integrations.md`). The Guardian Connector skills (section 7)
have their own rollout approval in 7.7 and are **not** in scope here.

---

## 0. What this deploy actually changes

Nothing in the registry changes shape. This work adds, behind the existing
optional switches:

- `scripts/superset_dashboard_ctl.py` — the REST helper for the actions MCP 6.1.0
  cannot reach (owner-reported issue: `Undefined` on `DashboardDeleteSchema`).
- `scripts/superset_mint_mcp_token.py` — mints the Bearer JWT the MCP needs.
- A CapRover-visible runbook (this file) plus the verified facts in section 8 of
  the integrations guide.
- `test/superset-e2e/` — the harness that produced those facts, so they are
  reproducible rather than asserted.

`WINDMILL` and `PG_MCP` are untouched. The new template variables
(`SUPERSET_MCP_URL`, `SUPERSET_MCP_TOKEN`) default to empty, so **an install
that leaves them empty is byte-identical to today's behaviour.**

---

## 1. Preconditions (all blocking)

| # | Condition | How to verify | Status |
|---|---|---|---|
| P1 | Superset is exactly `6.1.0` | `docker exec <superset> pip show apache-superset` | operator |
| P2 | `flask-caching==2.3.0` + `fastmcp==3.1.0` installed | `pip show flask-caching fastmcp` | operator |
| P3 | `superset mcp run` reachable behind **https** | `curl -sf https://<host>:5008/mcp` | operator |
| P4 | An `MCP_DEV_USERNAME` service per role exists | one process, one `MCP_DEV_USERNAME` | operator |
| P5 | Agent account created, non-Admin, `MCP_DashboardAgent` role | logs in; `User List` shows the role | operator |
| P6 | Role carries only the 10 permissions in guide §1.2 | `Security` -> `List Roles` | operator |
| P7 | `datasource_access` + `database_access` granted per guide §1.2 | `Datasets` tab on the role | operator |
| P8 | A Minted JWT secret is shared with the MCP process only | `MCP_JWT_SECRET` never in the api app env | operator |
| P9 | HTTPS enabled and **Force HTTPS** on `librechat` before first login | login works, no loop | operator |

P1 is not negotiable: every claim in the guide was verified against the `6.1.0`
tag, and `main`/`7.x` invalidate them.

---

## 2. Roles, explicitly

| Who | Superset role | May do | May **not** do |
|---|---|---|---|
| The MCP process | `MCP_DashboardAgent` (non-Admin) | list/read; `generate_chart`, `update_chart`, `generate_dashboard`, `add_chart_to_existing_dashboard`, `create_virtual_dataset`; plus the REST helper operations | read datasets it has no `datasource_access` on; use other users' objects as owners; `execute_sql`; `save_sql_query` |
| The REST helper | logs in **as the same agent account** | the semantic operations in guide §1.11 | anything Admin-only; it never uses ownership as an authorisation decision |

`execute_sql` and `save_sql_query` are **denied** — observed live, not inferred
(guide §8.2). That is the row-count guard: without it the agent could run
arbitrary SQL against the warehouse through a permission nobody granted.

The two MCP processes in the harness are separate **non-admin** users
(`librechat-agent`, `e2e-writer`) precisely because ownership is the boundary.
Cross-role access was refused in both directions (§8.2).

---

## 3. Procedure

### 3.1 Prepare Superset (before touching CapRover)

1. `pip install "apache-superset[fastmcp]==6.1.0" "flask-caching==2.3.0" "fastmcp==3.1.0"`.
   Without the `flask-caching` pin `superset init` fails.
2. Create the role exactly per §1.2 (10 permissions, no more).
3. Create the agent user, assign the role, set a password, log in once to confirm.
4. Grant `datasource_access` on each dataset and `database_access` on each
   connection the agent needs. Nothing else.
5. Mint the bearer token (throwaway secret for a smoke test, the real one for
   production):
   ```bash
   MCP_JWT_SECRET=<shared secret> python3 scripts/superset_mint_mcp_token.py \
     --sub librechat-agent --iss <issuer> --aud superset \
     --scopes 'mcp:read' --days 90
   ```
6. Start one process per role:
   ```bash
   MCP_DEV_USERNAME=librechat-agent MCP_JWT_SECRET=<secret> \
     superset mcp run --host 0.0.0.0 --port 5008
   ```
   A single process cannot serve two identities in 6.1.0 — `MCP_DEV_USERNAME`
   is read once at boot.

### 3.2 Smoke test against the production Superset (before any user sees it)

Run from a machine that can reach both. **This is the step that closes §8.4's
HTTPS gap**, so it is not optional or deferrable:

```bash
export SUPERSET_URL=https://superset.example.com \
       SUPERSET_USERNAME=librechat-agent SUPERSET_PASSWORD=<password>

# read path
./scripts/superset_dashboard_ctl.py show dashboard 5

# one write, on a dashboard that costs nothing to break
./scripts/superset_dashboard_ctl.py create-tab <scratch-dashboard-id> --name "smoke."

# one mutation that fails, to prove the guard is live
./scripts/superset_dashboard_ctl.py delete-chart <chart-the-agent-does-not-own>
```

Expected: `show` returns the layout; `create-tab` converts the grid; the
`delete-chart` refuses with `the agent account does not own it`.

If `create-tab` returns a CSRF error, the `X-CSRFToken`/cookie handshake is
broken behind your edge (proxy stripping `Set-Cookie`, `Referer` host not
matching). Fix that **before** continuing — it is the most likely production-only
failure, and it cannot be caught by the local http harness.

### 3.3 Deploy the registry changes

```bash
git checkout master && git merge librechat   # or cherry-pick the commits
git push origin master
```
`deploy.yml` runs `npm run publish` -> `build_one_click_apps_from_v4.js` ->
`gh-pages`. Verify before telling anyone:

```bash
curl -sf https://caprover-apps.comapeo.cloud/v4 | python3 -c \
  'import json,sys; print([a["name"] for a in json.load(sys.stdin)["oneClickApps"]])'
```
`librechat` must still be listed; the two new variables appear only when the app
is opened.

### 3.4 In CapRover

1. On the existing `librechat` app: **App Configs -> App Version**
   `https://caprover-apps.comapeo.cloud/v4/apps/librechat.yml`, Save & Update.
   New variables render with their defaults (empty = disabled).
2. Set `SUPERSET_MCP_URL=https://<host>:5008/mcp` and `SUPERSET_MCP_TOKEN=<jwt>`.
   Plain `http://` is rejected at boot **except** for
   `http://srv-captain--<name>` on the same CapRover.
3. Save & Update. Wait for the boot line `librechat-boot` naming the MCP entry.
4. In LibreChat: sign in, open the agent, confirm the Superset tools appear as
   **24** tools (guide §1.4).
5. Ask the agent to list dashboards. It must name only dashboards it has
   `can_read` on.
6. Ask it to rename a scratch dashboard's **title**. Titles work; **descriptions**
   are refused by `DashboardPutSchema` — that is the documented 6.1.0 limit, not a
   misconfiguration. If it needs a description, use the UI or an Admin.

### 3.5 Optional, separate approvals

- Guardian Connector skills (`GC_SKILLS_*`): off. Per §7.4 they publish **public**
  prompts to every account. Rollout steps in §7.7 — a different decision from
  this one.
- `PG_MCP`, `WINDMILL`: unchanged, no deployment action.

---

## 4. Rollback

Not applicable to the app — clearing `SUPERSET_MCP_URL` and redeploying removes
the entry. For a bad registry state:

```bash
git revert <merge-commit> && git push origin master    # 3.3 republishes
# then in CapRover: App Version -> Save & Update to re-render the old template
```
Nothing writes to Superset during rollback. The agent's own Superset objects
dashboards, charts, virtual datasets — persist; they are not app state.

For an unrecoverable CapRover state, restore per §4 of the integrations guide
(MongoDB dump + volume tars, taken *before* the update).

---

## 5. Verification matrix

| Step | Evidence that it actually happened |
|---|---|
| P1-P8 | commands above, pasted into this file's history |
| 3.2 | the three helper calls, with outputs |
| 3.3 | the `curl` output listing `librechat` |
| 3.4 | boot log line, tool count, dashboard list |
| Every existing case | `npm run test_librechat` (includes the GC matrix) |
| Superset helper | `npm run test_superset_ctl` |
| Registry + template | `npm run validate_apps && npm run formatter` |
| Full harness, reproducible | `test/superset-e2e/run.sh` — 24 tools, agent 16/0, cross-role 3/0, helper 24/0, memory bounded |
| HTTPS path (now covered) | `test/superset-e2e/tls_check.sh` — 24/24 over `https://localhost:18443` |

---

## 6. Known limits to state plainly at go/no-go

1. **HTTPS is now covered locally, not against a public issuer.** `tls_check.sh`
   passes 24/24 through nginx with a self-signed cert, which proves the CSRF and
   `Referer` handshake for the https URL shape and shows that the helper verifies
   the certificate chain. Not covered: a publicly-trusted CA and a real edge
   proxy. Step 3.2 is still the first contact with *your* edge.
2. **`execute_sql` is denied by design.** The agent cannot run ad-hoc SQL. Any
   requirement for that is a role change, i.e. a new risk decision.
3. **Descriptions cannot be set over REST** for dashboards. Titles work.
4. **A chart on another user's dashboard cannot be deleted** by the agent, even
   one it owns (`dashboard_slices.slice_id ON DELETE CASCADE` would silently
   remove it elsewhere). The helper refuses. Detach first.
5. **Virtual datasets are advisory** (§1.3) — the model cannot browse all tables;
   tell it the dataset name.
6. **A second identity needs a second process** (`MCP_DEV_USERNAME`), not a
   second URL to the same process.
