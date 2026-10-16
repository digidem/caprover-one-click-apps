# Production deployment plan — Superset MCP integration

Target: CapRover app `librechat` from
`public/v4/apps/librechat.yml` in this repo, published to
`https://caprover-apps.comapeo.cloud/v4`.
Scope: the Superset MCP integration (sections 1 and 1.11 of
`docs/librechat-integrations.md`). The Guardian Connector skills (section 7)
have their own rollout approval in 7.7 and are **not** in scope here.
Note the registry URL shape: the build emits `v4/apps/librechat` and `v4/list`
with **no `.yml` extension** (`scripts/build_one_click_apps_from_v4.js`), so use
those paths when verifying, not `v4/apps/librechat.yml`.

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

## 1. Preconditions

The status column is the point: what was verified, by whom, and against what.

| # | Condition | How to verify | Status |
|---|---|---|---|
| P1 | Superset is exactly `6.1.0` | From the app's **Logs** tab, the boot banner prints the version. `docker exec … pip show` only works on a host with shell access. | **live, unchecked** |
| P2 | `flask-caching==2.3.0` + `fastmcp==3.1.0` installed | Boot log; a missing `flask-caching` makes `superset init` fail outright | **live, unchecked** |
| P3 | `superset mcp run` reachable behind **https**, and the JWT gate refuses bad tokens | `curl -i https://<host>/mcp` → must be `401`, **not** `404`. Then POST a token signed with the wrong key, and an expired one: both must be `401`. | **verified 2026-10-15** (see §6.1) |
| P4 | An `MCP_DEV_USERNAME` service per role exists | one process, one `MCP_DEV_USERNAME`; a single process cannot serve two identities | **live, unchecked** |
| P5 | Agent account exists, non-Admin, holds the intended role — in production `svc-chat-mcp` / `chat-mcp` | `User List` shows the role, and it is **not** Admin | **live, unchecked** |
| P6 | Role carries **only** the 10 permissions in guide §1.2 | `Security` → `List Roles` → the role | **live, unchecked** |
| P7 | `datasource_access` + `database_access` granted per guide §1.2 | `Datasets` tab on the role | **live, unchecked** |
| P8 | `MCP_JWT_SECRET` shared with the MCP process **only** | never in the api app env; the api app only holds the minted token | **live, unchecked** |
| P9 | The MCP process overrides the image healthcheck | The image's healthcheck curls `$SUPERSET_PORT/health`. With the command changed to `superset mcp run`, Docker kills the task every ~100s unless `Healthcheck: NONE` is set in the service override. | **must be checked before (re)deploying the MCP process** |
| P10 | A backup of Superset's metadata database exists | a dump taken **before** the MCP was enabled | **unknown — dashboards and charts are not versioned** |

P5–P8 are **the audit**, not a checklist: Superset MCP is already in production,
so nobody has confirmed since 2026-10-13 that the role is still the ten
permissions and nothing more. That is the first thing to look at.

---

## 2. Roles, explicitly

| Who | Superset role | May do | May **not** do |
|---|---|---|---|
| The MCP process | `MCP_DashboardAgent` (non-Admin) | list/read; `generate_chart`, `update_chart`, `generate_dashboard`, `add_chart_to_existing_dashboard`, `create_virtual_dataset` | read datasets it has no `datasource_access` on; use other users' objects as owners; `execute_sql`; `save_sql_query` |
| The REST helper | logs in **as the same agent account** | the semantic operations in guide §1.11 | anything Admin-only; it never uses ownership as an authorisation decision |

`execute_sql` and `save_sql_query` are **denied** — observed live, not inferred
(guide §8.2). That is the row-count guard: without it the agent could run
arbitrary SQL against the warehouse through a permission nobody granted.

Two things that are easy to over-read:
- **The REST helper is not part of the deployed app.** The template does not ship
  `superset_dashboard_ctl.py`, so its guards (shared-chart cascade, dataset
  dependants) protect an operator running it by hand, not the agent. The agent's
  boundary is the role only.
- **Every chat user is the same Superset user.** `MCP_DEV_USERNAME` pins the
  acting identity per process, so Superset's audit log cannot tell them apart.

The two MCP processes in the harness are separate **non-admin** users
(`librechat-agent`, `e2e-writer`) precisely because ownership is the boundary.
Cross-role access was refused in both directions (§8.2).

---

## 2.5 Audit the live deployment first (it is already running)

Do this before anything else. It is read-only and takes minutes.

### What an outsider could check (done 2026-10-15, no credentials needed)

| Check | Result |
|---|---|
| `https://superset-mcp.javari.guardianconnector.net/mcp` | answers **401** to a POST with no bearer, to a token signed with the wrong key, and to an expired token. The JWT gate is up, and it fails closed on all three. |
| `https://chat.javari.guardianconnector.net/` | 200, HSTS on. The api app is healthy. |
| `/api/config` on chat | `registrationEnabled: false`. The GC-skills precondition in guide §7.4 is already satisfied. |
| `/api/config` `mcpServers` | **null**, and that is expected — LibreChat does not expose its MCP list there. It is not evidence either way. |

So the edge is sound. What that could **not** show from outside: whether the
agent account is still non-Admin, whether its role still holds exactly ten
permissions, what the agent has created, what the live process overrides, and
whether the deployed image carries the intended patch. Those need Superset and
CapRover access.

### Deployed state (updated 2026-10-16)

- **`superset-mcp` runs CapRover version 2**: image
  `communityfirst/superset-mcp:6.1.0-ownercheck-20261015`
  (`sha256:113dab3978767a91e5c582e2958f56bf26f4b357bb51fa1507f6f875c94fa3ec`),
  deployed 2026-10-15 by digest via `rastro_caprover.py deploy-image --execute`
  (build on the laptop, push, deploy by tag — no on-host build).
  The image is the stock 6.1.0 base plus one patch:
  `add_chart_to_existing_dashboard` now requires `raise_for_ownership(chart)`
  before `check_chart_data_access` (Dockerfile: `~/javari-ops/superset-mcp-Dockerfile`;
  the e2e harness carries the identical patch and asserts the refusal).
- **Env and override survived the deploy**: nine env vars including
  `MCP_RBAC_ENABLED=True`, and the service override with `Healthcheck: NONE`,
  the `superset mcp run` command, and the 1.5 GiB memory limit.
- **Verified after deploy**: public gate 401 without a token / 200 with chat's
  token listing 24 tools, sustained over repeated polls; production LibreChat
  test 2026-10-16 **9/9 PASS**, including the foreign-chart refusal and the
  foreign-dashboard denial (dashboard 1, "Painel do Univaja").
  `svc-chat-mcp` roles observed: Gamma + `chat-mcp`, non-Admin.
- **Image rollback**: CapRover dashboard → version 1
  (`img-captain-superset-mcp:1`), still in the version list. A definition backup
  taken before the deploy lives at
  `~/javari-ops/backups/superset-mcp-def-pre-ownercheck-20261015.json`
  (mode 600, contains secrets).

### What still needs the Superset/CapRover console

1. **Is the gate up?** `curl -i https://superset-mcp.javari.guardianconnector.net/mcp`
   must return `401`, not `404`. A 404 means the process is down and chat's
   Superset tools are already dead.
2. **What does the agent account actually hold?** `Security → List Roles →
   chat-mcp`, then its permissions. It must be exactly the ten in
   guide §1.2. Anything extra — `can_delete`, `can_write` on Database, any
   `all_datasource_access` — is drift and should be removed.
3. **Is the agent account non-Admin?** In production the account is
   **`svc-chat-mcp`** (role `chat-mcp`). `User List → svc-chat-mcp`. If that one
   field says Admin, every other control in this document is void. `librechat-agent`
   is a placeholder from the guide; go by what `User List` actually shows.
4. **What has it created?** `Dashboards` and `Charts` where the owner is the
   agent. This is the inventory nobody has. Compare against what the chat users
   expected it to do — duplicated charts and orphan virtual datasets are the
   known failure mode.
5. **Has the layout been rewritten?** Open each agent-owned dashboard. Layout
   edits have no undo, so this is also the moment to dump Superset metadata
   (P10) if that still has not happened.
6. **Token expiry.** Find the mint date of the live token. If it was minted
   2026-10-13 with `--days 90`, it expires around 2027-01-11. Put that date in a
   calendar now.
7. **Is the healthcheck overridden?** Check the service override on the
   `superset-mcp` app for `Healthcheck: NONE`. If it is missing, the container is
   being killed every ~100s (see P9) — which outside looks like the endpoint
   flapping, not like a misconfigured healthcheck.

---

## 3. Procedure

### 3.1 Prepare Superset — **already done in production**, so this section is for
a rebuild, a second identity, or version drift found in §2.5

1. `pip install "apache-superset[fastmcp]==6.1.0" "flask-caching==2.3.0" "fastmcp==3.1.0"`.
   Without the `flask-caching` pin `superset init` fails.
2. Create the role exactly per §1.2 (10 permissions, no more).
3. Create the agent user, assign the role, set a password, log in once to confirm.
4. Grant `datasource_access` on each dataset and `database_access` on each
   connection the agent needs. Nothing else.
5. Mint the bearer token:
   ```bash
   MCP_JWT_SECRET=<shared secret> python3 scripts/superset_mint_mcp_token.py \
     --sub <the acting user, e.g. svc-chat-mcp> --iss <issuer> --aud superset \
     --scopes 'mcp:read' --days 90
   ```
   Remember `--scopes` is **not enforced** (§6.6): it does not restrict anything.
6. Start one process per role, **and override the healthcheck**:
   ```bash
   MCP_DEV_USERNAME=svc-chat-mcp MCP_JWT_SECRET=<secret> \
     superset mcp run --host 0.0.0.0 --port 5008
   ```
   A single process cannot serve two identities in 6.1.0 — `MCP_DEV_USERNAME`
   is read once at boot. The image's healthcheck curls `$SUPERSET_PORT/health`,
   so an MCP-only container with the command changed must set
   `Healthcheck: NONE`, or Docker kills the task every ~100 s.

### 3.2 Smoke test against the production Superset (before any user sees it)

Run from a machine that can reach both. **This is the step that closes §8.4's
HTTPS gap**, so it is not optional or deferrable:

```bash
export SUPERSET_URL=https://superset.example.com \
       SUPERSET_USERNAME=svc-chat-mcp SUPERSET_PASSWORD=<password>

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

### 3.3 Publish the template

`master` has already been merged and `deploy.yml` publishes to `gh-pages`
(`npm run build` -> the static site). Verify what the **live** registry serves,
because that is what CapRover reads:

```bash
# the list: /v4/list (no .yml, and note the trailing content is JSON)
curl -sf https://caprover-apps.comapeo.cloud/v4/list | python3 -c \
  'import json,sys; print([a["name"] for a in json.load(sys.stdin)["oneClickApps"]])'
# the template itself
curl -sf -o /dev/null -w '%{http_code}\n' \
  https://caprover-apps.comapeo.cloud/v4/apps/librechat
```

**Observed 2026-10-15:** the live registry served only `comapeo-cloud` and
`rastro`; `v4/apps/librechat` returned 404. So until `librechat` appears in that
list, no fresh install can select it, and the deploy is not finished regardless of
what CI says. Our `gh-pages` branch holds the right content but is not what that
hostname serves.

### 3.4 In CapRover

**A one-click template is applied at install time, not re-rendered on update.**
There is no "App Version -> re-render" step for an existing app: an already
deployed app picks up new behaviour only through its env vars or a service
override. Concretely, for the existing production `chat` app:

1. `App Configs` -> env: set `SUPERSET_MCP_URL=https://<host>/mcp` and
   `SUPERSET_MCP_TOKEN=<jwt>`.
2. Save & Update, then wait for the `librechat-boot` line in the api app logs
   naming the MCP entry.

Do **not** drive this through the CapRover API's app-update call: that path drops
the app's `domains`, which breaks its HTTPS. Use the dashboard UI.
3. In LibreChat: sign in, open the agent, confirm the Superset tools appear as
   **24** tools (guide §1.4).
4. Ask the agent to list dashboards. It must name only dashboards it has
   `can_read` on.
5. Ask it to rename a scratch dashboard's **title** — but first confirm an MCP
   tool exists that does this. The REST helper's `rename-dashboard` is **not**
   shipped in the template, so it cannot be counted on for the agent (see 4.2).
   **Descriptions** are refused by `DashboardPutSchema` — that is the documented
   6.1.0 limit, not a misconfiguration.

### 3.5 Optional, separate approvals

- Guardian Connector skills (`GC_SKILLS_*`): off. Per §7.4 they publish **public**
  prompts to every account. Rollout steps in §7.7 — a different decision from
  this one.
- `PG_MCP`, `WINDMILL`: unchanged, no deployment action.

---

## 4. Rollback

### 4.1 Turning the integration off

Ordered fastest first. None of these writes to Superset.

1. **Scale `superset-mcp` to 0** on its host. Cuts access immediately; nothing
   in `chat` needs touching. Best first move for an incident.
2. **Change `MCP_JWT_SECRET` on the MCP process.** Every issued token stops
   verifying at once, and it needs no redeploy of `chat`.
3. **Clear `SUPERSET_MCP_URL`** on the api app, through the dashboard UI (never
   the API update path — it drops `domains` and breaks chat's HTTPS), redeploy.
   Removing the env var removes the MCP entry.
4. **Deactivate the agent user** in Superset. The strongest of the four: it cuts
   both the MCP process *and* the REST helper, while leaving the agent's own
   charts, dashboards and virtual datasets in place.

The registry is not part of rolling back a running app. Reverting `master`
republishes the template; it changes nothing that is already installed.

### 4.2 The one thing with no undo

**Superset does not version dashboards or charts.** Once the agent rewrites a
dashboard's layout, edits a chart's definition, or deletes a chart, there is no
"undo" in 6.1.0 — deletes are hard (no trash), and a stray child reference is
what the helper guards against precisely because it is unrecoverable.

So: **back up Superset's metadata database before enabling the MCP**, not after.
Without that dump, enabling the MCP is a one-way door for layout edits.

Note also what does **not** hold here: the guards I wrote in
`scripts/superset_dashboard_ctl.py` (the shared-chart cascade guard, the
dataset-dependants guard) protect a human running that helper by hand. The
template does not ship that script, so **the agent gets none of those guards**.
The agent's limit is its Superset role alone. State that plainly to whoever
approves this.

For an unrecoverable CapRover state, restore per §4 of the integrations guide
(MongoDB dump + volume tars, taken *before* the update).

---

## 5. Registry: what is actually published, and where

Two things that look like one thing:

- **The live registry** is `https://caprover-apps.comapeo.cloud/v4/`, served by
  the operator's own nginx at `167.172.33.4` (the A record of that CNAME). It is
  healthy: `/v4/list` returns 200 with `comapeo-cloud` and `rastro`. **`librechat`
  is not there** — `v4/apps/librechat` returns 404. This is the URL CapRover
  reads, and it is a *mirror of this repo's build*, not this repo's `gh-pages`.
- **This repo's `gh-pages`** is served by GitHub Pages (enabled 2026-10-15, CNAME
  set, branch `gh-pages`, `.nojekyll` present) and holds the correct content
  including `librechat`. It is **not** what that hostname resolves to, and
  `digidem.github.io` as a whole 301-redirects to `lab.digital-democracy.org`,
  which masks it further.

So the deploy succeeds and changes nothing a user can install, because the
registry that matters is the operator's nginx. Getting `librechat` into it means
either publishing `dist/` to that host (a step only whoever controls
`167.172.33.4` can perform), or repointing the CNAME at GitHub Pages' IPs and
waiting for its certificate — the latter is a **cutover**, because that nginx
already serves `comapeo-cloud` and `rastro` to existing installs, and GitHub
Pages would serve them from this repo instead. Confirm the content matches
(`curl https://caprover-apps.comapeo.cloud/v4/apps/rastro` vs
`git show origin/gh-pages:v4/apps/rastro`) before anyone touches DNS.

**Do not treat a green deploy workflow as evidence the template is live.**

---

## 6. Verification matrix

| Step | Evidence that it actually happened |
|---|---|
| §2.5 audit, step 1 | `curl -i <mcp>/mcp` → `401` (not `404`), plus wrong-key and expired tokens both `401` — **done 2026-10-15** |
| §2.5 audit, steps 2-6 | screenshots of the role, the user, and the inventory of agent-owned objects |
| §3.2 | the three helper calls, with outputs |
| §5 registry | `curl …/v4/list` **listing `librechat`**, and `curl …/v4/apps/librechat` → 200 — **not yet true** |
| §3.4 | boot log line, tool count, dashboard list |
| Every existing case | `npm run test_librechat` (includes the GC matrix) |
| Superset helper | `npm run test_superset_ctl` |
| Registry + template | `npm run validate_apps && npm run formatter` |
| Full harness, reproducible | `test/superset-e2e/run.sh` — 24 tools, agent 16/0, cross-role 3/0, helper 24/0, memory bounded |
| HTTPS path (local only) | `test/superset-e2e/tls_check.sh` — 24/24 over `https://localhost:18443` |

---

## 7. Known limits to state plainly at go/no-go

1. **Superset MCP is already live in production.** Verified 2026-10-15:
   `https://superset-mcp.javari.guardianconnector.net/mcp` answers 401
   `invalid_token` with no bearer, with a token signed by the wrong key, and with
   an expired token. That is the public JWT gate working from the outside. It also
   means the rollout is not ahead of us — the audit is. What that probe cannot see
   is whether the agent account still holds only its intended role, or what it has
   already created.
2. **Every LibreChat user acts as the same Superset user.** `MCP_DEV_USERNAME`
   fixes the acting identity per process, so Superset's audit log cannot
   distinguish one chat user from another. One shared identity, one audit trail.
3. **The agent gets none of the REST helper's guards** (see 4.2). Its boundary is
   the Superset role, full stop.
4. **`execute_sql` is denied by design.** The agent cannot run ad-hoc SQL. Any
   requirement for that is a role change, i.e. a new risk decision.
5. **A token has an expiry and nothing renews it.** A 90-day token minted on
   2026-10-13 expires around 2027-01-11; when it does, the gate refuses every
   request with `invalid_token` and chat's Superset tools silently die. Put the
   expiry in a calendar and mint the replacement before, not after.
6. **`--scopes 'mcp:read'` is advisory only.** `scripts/superset_mint_mcp_token.py`
   documents that the scope claim is verified but there is **no per-tool scope
   enforcement** in 6.1.0, so a write tool with a `mcp:read` token still writes.
   Do not read that flag as a safety boundary.
7. **The image healthcheck will kill an MCP-only container.** The official
   Superset image's healthcheck runs
   `curl -f http://localhost:${SUPERSET_PORT}/health`. If you override the command
   to `superset mcp run --port 5008`, nothing answers `/health` on 5008 and Docker
   kills the task every ~100s. The service override must set
   `Healthcheck: NONE`.
8. **Dashboards and charts are not versioned** — see 4.2. Back up Superset metadata
   before enabling, not after.
9. **Virtual datasets are advisory** (§1.3) — the model cannot browse all tables;
   tell it the dataset name.
10. **A second identity needs a second process** (`MCP_DEV_USERNAME`), not a
    second URL to the same process.
11. **HTTPS is covered locally, not against a public issuer.** `tls_check.sh`
    passes 24/24 through nginx with a self-signed cert, which proves the CSRF and
    `Referer` handshake for the https URL shape. Not covered: a real edge proxy
    and a real CA, i.e. the exact path production takes.
