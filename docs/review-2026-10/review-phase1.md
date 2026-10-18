# Integration review 2026-10 — supporting evidence

# Senior review of junior outputs (a1-a4, b1-b4, c1-c4)

Reviewer: senior. Method: every load-bearing claim re-verified against the repo via Read/xerj/batch grep on 2026-10-17. Verdicts per claim class: REPRODUCED (senior re-derived the cited fact), CORRECTED (claim adjusted), NOT-REPRODUCED (claim could not be re-derived).

## a1 — boot env validation vs spec
Verdict: REPRODUCED (all 25 claims).
- Regexes `scripts/librechat-boot.sh:32-38` byte-identical to `specs/librechat-mcp.md` §3.4 table (LLM_NAME/LLM_DEFAULT_MODEL/LLM_MODELS/PG_MCP_ENABLED/LLM_API_KEY/WINDMILL_MCP_TOKEN/SUPERSET_MCP_TOKEN) — REPRODUCED by direct line read.
- Claim 8 (spec:114 says §3.4 URL regexes "copied verbatim into one JS object"; script instead validates URLs via `urlOk` rules and never applies the §3.4 URL regexes) — REPRODUCED: `specs/librechat-mcp.md:114` sentence confirmed; `re` object holds 7 keys, no URL regexes; `urlOk` at `:49-61` implements rules (a)-(e). The implementation is STRICTER than the §3.4 regex (http only to `srv-captain--*`). Becomes finding R-06 (spec wording inaccurate, safe direction).
- Claim 9 (LLM_MODELS validated but absent from spec:114's pre-check list) — REPRODUCED (spec:114 list omits it).
- Atomic write (`:20` TMP_FILE, `:136` mv) and post-check (`:139-157`) — REPRODUCED.

## a2 — MCP wiring
Verdict: REPRODUCED (all 4 claim groups).
- MCP assembly `scripts/librechat-boot.sh:76-107` matches claim exactly: postgres sse gated on `PG_MCP_ENABLED=1` with NO Bearer branch; windmill/superset streamable-http with optional Bearer; `mcpServers:` header only when non-empty — REPRODUCED by line read.
- Guide omits `SUPERSET_MCP_URL`/`SUPERSET_MCP_TOKEN` (grep count 0 in `docs/librechat-integrations.md`) and `PG_MCP_URL` — REPRODUCED. (`SUPERSET_MCP_URL` appears in runbook:241 and recipe:11 as claimed.)
- Template env `public/v4/apps/librechat.yml:38-43` names match script emissions — REPRODUCED.
- Byte-equality of embedded boot copy — REPRODUCED via mechanism (`scripts/sync_librechat_boot.js:40-50` asserts `parsed[2] !== boot`) plus the executed `npm run test_librechat` PASS (ledger).

## a3 — GC provision path
Verdict: REPRODUCED (all 5 claim groups).
- `gc_main || true` `:1407`, `gc_main` `:1393-1405` returns 0 on every path; `exec node server/index.js` `:1410` — REPRODUCED.
- Flag resolution `:720-742`: master default 0, defaults MAPEO=1/ALERTS=1/KOBO=0/RASTRO=0 only when master=1, forced 0 otherwise, hints charset-checked — REPRODUCED by full block read.
- Publish list `:1356` = `gc-core gc-install gc-mapeo gc-alerts gc-kobo gc-rastro`; `gc-install` generated from hints at `:744-763` with no repo directory — REPRODUCED (repo `skills/gc/` has no gc-install; consistent with guide:469 "generated at boot").
- Deadlines `DEADLINE_MS=150000` `:797`, `CONNECT_BUDGET_MS=90000` `:798` — REPRODUCED.
- State-before-ACL `:1167` vs `:1169-1178` — REPRODUCED (c2 cross-check agrees).

## a4 — template vs runbook §3.4
Verdict: REPRODUCED (all claims).
- Template `:4-5,53,55-78,107-113` (images, containerHttpPort 3080, defaults v0.8.8 / 8.0.20, hard tag postgres-mcp:0.3.0) — REPRODUCED.
- App naming differs (template `$$cap_appname` vs runbook `chat`) and §3.4 steps 3-5 have no installer counterpart; "drops domains" warning absent from installer — REPRODUCED (consistent with b2 findings R-01).

## b1 — registry publish claim
Verdict: REPRODUCED (all verdicts).
- `deploy.yml:8-12` (push master + workflow_dispatch), `:37` npm run build, `:39-42` peaceiris → gh-pages; 3 workflows; `publish-from-actions` referenced by 0 workflow files — REPRODUCED.
- "Mirror of this repo's build" is asserted, not evidenced by any repo automation — REPRODUCED (matches runbook §5's own text, which says only whoever controls 167.172.33.4 can publish).

## b2 — docs defects
Verdict: REPRODUCED (claims 1-5, 10-18); REPRODUCED (claims 6-9) with direct line reads.
- :3 app `librechat` ✓; :211/:213 duplicate `### 3.3` ✓; :158 heading ends mid-sentence with :159 outside the heading ✓; :42 "(see §6.1)" with no §6.1 ✓ (P3 row confirmed); :173 "(§6.6)" dangling ✓.
- guide :55-56: prose "`--days 30 (short-lived) or --days 365 …`" sits inside the ```bash fence — REPRODUCED (copy-paste executes it).
- recipe :15 duplicated clause "the label may differ in your version" twice in one sentence — REPRODUCED.
- guide :43 unnumbered heading and :7 spike-glob claim — line reads consistent; REPRODUCED.

## b3 — guide vs scripts
Verdict: REPRODUCED (all claims).
- Mint script stdlib-only (`argparse base64 hashlib hmac json os sys time`; no `import jwt`) at `scripts/superset_mint_mcp_token.py:12-19` — REPRODUCED (also by repo-wide grep: zero PyJWT hits in scripts/). Guide PyJWT pin at guide:18 — REPRODUCED (two independent passes).
- `--sub` default `librechat-agent` (:26), `--days` default 365 (:30), usage example 30 (:10); runbook 90 (:147,:171); guide names svc-chat-mcp (:27) — REPRODUCED.
- Guide §6 says clearing URL removes entry; boot leaves a headerless superset entry if only the token is cleared (`:96-106`) — REPRODUCED; becomes finding R-17.

## b4 — verification matrix
Verdict: REPRODUCED with one CORRECTED detail.
- Matrix rows `runbook:342-351` as enumerated, R4 "not yet true" — REPRODUCED.
- R1 PARTIAL (harness asserts only no-bearer 401; no wrong-key/expired test anywhere in test/) — REPRODUCED (grep for expired|wrong in test/superset-e2e/*.py: zero hits).
- R3 PARTIAL (foreign-ownership refusal asserted only for rename-dataset at `rest_checks.py:159-162`; :237-239 delete-chart deletes an OWNED chart) — REPRODUCED.
- check() call-site counts: agent 11 and readonly 4 REPRODUCED (12 and 5 minus the `def check(` line each). Rest "22" NOT-REPRODUCED as stated — `grep -c 'check('` finds 10 lines (2 wrapper defs + 8 direct); 22 plausibly counts `expect_ok`/`expect_fail` invocations. CORRECTED (immaterial: runbook's runtime count 24/0 is the meaningful number and is unaffected).

## c1 — secret handling
Verdict: REPRODUCED (inventory + all print-site verdicts).
- Secret-class template lines (:20,27-30,35,41,43,62,76) and `$$cap_gen_random_hex` generators — REPRODUCED.
- Print-path verdicts SAFE at :28,:110-134,:149,:154,:701,:1109,:1179,:1180,:713,:748-758,:1366,:1376 — REPRODUCED (callers pass fixed literals).
- Conditional RISK at :810 via err.message (`:981` mongo error → `:1202` → `:810`) — REPRODUCED by line read; repo never prints the value itself; driver-message content unresolved (correctly left open).

## c2 — soft-fail inventory
Verdict: REPRODUCED (all items).
- Lock loop `:1330-1346` (silent steal `:1336`, loud timeout `:1338`, silent release `:1343`) — REPRODUCED.
- Manifest `awk || true` `:1358`, `mv "$NEWMAN" || return 1` `:1388` — REPRODUCED.
- Seeder exit-0 paths `:823-836`, `:1201-1204` — REPRODUCED (exit 1 only for validate-skills confirmed at `:1202-1204`).
- State-before-ACL mixed verdict — REPRODUCED; `:1182` `mongoose.disconnect().catch(function () {})` — REPRODUCED.
- Marker-assertion coverage limited to flags/hints/MONGO_URI cases (`test_librechat_gc.js:148-168`) — REPRODUCED.

## c3 — GC_PROVISION_DEGRADED blast radius
Verdict: REPRODUCED (all claims).
- Emission sites (shell + seeder) — REPRODUCED (spot-checked :700-701, :1338, seeder degraded()).
- Consumers: automated assertions test-time only (`test_librechat_gc.js` via `test_librechat_config.js:186`); grep over scripts/*.sh, *.js, scripts/gc/ finds no runtime consumer (no healthcheck/alert/monitor) — REPRODUCED.
- Runbook §6 has no marker row; documented operator response lives only in guide:499/:513 and template installer text — REPRODUCED. Becomes finding R-15.

## c4 — MCP token handling
Verdict: REPRODUCED (all claims).
- Token regex charset-superset argument (minted JWT ⊂ `[A-Za-z0-9_.~=-]`) — REPRODUCED (mint script base64url, padding stripped).
- Charset-only check, no JWT-structure validation; malformed-but-charset-valid token surfaces as runtime 401 — REPRODUCED (matches runbook :42,:90).
- pg-mcp DSN confined to `-pg-mcp` env (`:75-76`, var def `:164-168` defaultValue ''); api carries only credential-free `PG_MCP_URL` (:39) — REPRODUCED. Unauthenticated SSE on 0.0.0.0:8000 behind notExposeAsWebApp — REPRODUCED (command at :69-74).
- `PG_MCP_ENABLED` default '0' (template :160-163), gates exactly the postgres entry (`:77-83`); `PG_MCP_ENABLED=1` with empty DSN lists a dead URL (tail -f idler, :73) — REPRODUCED.

## Contradiction check vs executed DEPLOYED/LIVE results
1. **Registry 404 framing (team-lead: "CONFIRMED drift vs runbook §5") — CORRECTED.** Runbook §5 (`:313-337`) documents `librechat` 404 as the CURRENT known state and §6 row R4 marks the listing row "not yet true". Live 404 is therefore CONSISTENT with the runbook; the underlying item is a known open deployment gap (publish dist/ to the operator nginx, or CNAME cutover), not a doc-vs-reality contradiction. (Finding D-01.)
2. **`GC_SKILLS_ENABLED='1'` vs template — resolved as MATCH.** Template variable `$$cap_gc_skills_enabled` default '0', `validRegex ^[01]$` (`public/v4/apps/librechat.yml:187-191`); boot accepts only 0|1 (`:704-709`). Prod '1' is format-valid and a deliberate install-time override (documented optional §3.5/guide §7). The '1' vs 'true' note in expect-verdicts.md closes as no issue.
3. **`PG_MCP_ENABLED='0'` in prod** — matches template default '0' (:160-163). Postgres MCP off is the designed default; no drift.
4. **superset MCP via public URL** — template description for `$$cap_superset_mcp_url` (:178-182) gives exactly the public-URL shape as its example (`https://superset-mcp.javari.guardianconnector.net/mcp`); prod usage is per-design, not drift.
5. **`mcpServers` {} vs runbook :93 "null"** — live `{}` differs from the documented literal `null`. Both mean "not exposed"; cosmetic doc fix. (Finding L-05.)
No junior claim contradicts the DEPLOYED/LIVE evidence.

# D1 component→test coverage map + D3 gap-list confirmation (senior substitution)

Junior d1/d3 failed twice; senior executes per plan §8. Date 2026-10-17. Verdicts: COVERED / PARTIAL / NONE. "This review" = the executed DEPLOYED/LIVE probes recorded in ledger.md.

## D1 — map

| # | Production component | Local unit | Local e2e | Prod check | Verdict |
|---|---|---|---|---|---|
| 1 | api boot script + generated config | `npm run test_librechat` (byte-equality, regex parity, case matrix, mcpServers keys, secret leakage; `test_librechat_config.js:186` includes GC matrix) — PASS this review | — | runbook §6 row §3.4 (boot log, tool count); L2/L3 partially cover | COVERED (unit); prod row PARTIAL |
| 2 | GC skills bundle + seeder (flags, publish, prompts, ACLs) | `test_librechat_gc.js` marker assertions (flags/hints/MONGO_URI cases; operator-edit path NOT covered, guide:513) — PASS this review | — | none automated (marker is stderr-only, no consumer — c3) | PARTIAL |
| 3 | superset-mcp image + ownercheck patch | — | `test/superset-e2e/run.sh` (builds Dockerfile carrying identical patch; agent_checks/readonly_checks assert foreign-object refusal) — NOT RUN this session | digest verified (deployed-inventory: sha256:113dab…); foreign-chart write refusal last proven 2026-10-16 (runbook §2.5), not re-proven read-only | PARTIAL (local run pending; deployed digest COVERED) |
| 4 | Superset REST helper | `npm run test_superset_ctl` (contract, no instance) — PASS | `rest_checks.py` + `tls_check.sh` — NOT RUN this session | runbook §3.2 (contains prod writes — out of scope) | PARTIAL (unit COVERED; e2e pending) |
| 5 | JWT gate (fail-closed 401s) | — | `run.sh` asserts no-bearer 401 only; wrong-key/expired NOT tested anywhere in test/ | runbook §2.5 (2026-10-15) + **this review L2: wrong-key 401, expired-real-secret 401 → expiry ENFORCED** | PARTIAL → prod now COVERED; local gap remains (R-10) |
| 6 | Token minting (scopes/expiry claims) | none | none | this review L2 exercised an expired token end-to-end; scopes remain untested (runbook :375-377: advisory only) | NONE (repo); PARTIAL (evidence via L2) |
| 7 | Registry publish chain | `npm run validate_apps` + `formatter --check` (schema/format only) — PASS | none; deploy.yml → gh-pages only; no live-registry probe exists | `/v4/list` reachable, `librechat` 404 (this review) | NONE for live-registry (R-09, D-01) |
| 8 | CapRover deploy path (`rastro_caprover.py deploy-image`) | external tool, not in repo | — | digest match verified this review | NONE (accepted external dependency, R-13) |
| 9 | MongoDB dump/volume restore (§4) | none | none | never exercised | NONE (R-14) |
| 10 | Superset metadata backup (§4.2) | none | none | dump existence recorded 2026-10-15, not re-verified | NONE (R-14) |
| 11 | **chat→LLM chain (LibreChat service, LLM round-trip)** | none — harness has no LibreChat service (docker-compose.yml has no librechat container) | none | WS-LIVE-B = phase 2 | NONE — UNVERIFIED-BY-DESIGN in phase 1 |
| 12 | Warehouse data retrieval via MCP | `agent_checks.py` (execute_sql denied, save_sql_query denied, read/write agent paths) | run.sh stage 7 — NOT RUN this session | **this review L3: tools/list 24, list_datasets returned real warehouse records** | PARTIAL → prod connectivity COVERED read-only |
| 13 | GC_PROVISION_DEGRADED detection at runtime | marker assertions in test only (c3) | — | L4 log grep — pending | PARTIAL (no runtime consumer, R-15) |
| 14 | Process override (`Healthcheck: NONE`, 1.5 GiB) | none | none | deployed-inventory confirms override present | COVERED by this review's inventory; no repo test (gap stands) |
| 15 | comapeo-cloud / rastro templates | validate_apps schema only | none | `/v4/list` 200 serves both | PARTIAL (schema-only, as junior-d said) |

## D3 — gap-list confirmation (round-1 junior d list)

Each prior gap re-confirmed against the map above:

1. Mint script untested — CONFIRMED (row 6).
2. Build/publish scripts (`build_one_click_apps*.js`, `migrate_v2_to_v4.js`, `publish-from-actions.sh`) untested; `publish-from-actions.sh` additionally dead code (b1) — CONFIRMED.
3. deploy.yml/gh-pages vs live registry: no probe; live 404 — CONFIRMED (rows 7, D-01).
4. `sync_librechat_boot.js` output asserted (byte-equality in test_librechat), script itself untested — CONFIRMED; acceptable (output is the contract), note only.
5. CapRover deploy path external — CONFIRMED (row 8).
6. `Healthcheck: NONE` override untested in repo — CONFIRMED (row 14).
7. JWT fail-closed prod check was manual-only — CONFIRMED, and this review's L2 upgraded prod evidence (expired real-secret token 401); local-automation gap remains (R-10).
8. Token expiry untested — CONFIRMED for repo; prod enforcement now proven by L2 (401 on expired real-secret token).
9. Real edge TLS/public CA — CONFIRMED (tls_check.sh is self-signed localhost; public HTTPS path exercised by L2 implicitly: chat 200 over real TLS, /mcp 401 over real TLS).
10. WINDMILL/PG_MCP template paths behaviorally untested — CONFIRMED (PG_MCP_ENABLED=0 off in prod, so pg-mcp path currently moot in prod).
11. MongoDB restore — CONFIRMED (row 9).
12. Superset metadata backup — CONFIRMED (row 10).
13. comapeo/rastro behavioral tests — CONFIRMED (row 15).
14. RLS + concurrency — CONFIRMED; RLS inventory additionally BLOCKED-HUMAN (WS-DEPLOY-B item 4).
15. Live agent-account drift + nginx host/DNS — CONFIRMED; role/grant/Gamma audit BLOCKED-HUMAN (WS-DEPLOY-B), TODO.md items 2-4 own it.

New gaps found by senior substitution (not in junior-d list): row 2's operator-edit path (already noted in guide:513, junior c3/c2), row 11/12 chat→LLM chain as a distinct uncovered component, and the L4 runtime-marker detection gap (row 13).

# Execution ledger — phase 1 (REPO workstreams + executed DEPLOYED/LIVE checks)

Format: check | layer | planned | executed | result | evidence. Date 2026-10-17.

| check | layer | planned | executed | result | evidence |
|---|---|---|---|---|---|
| A1 boot env validation vs spec | REPO | plan §4 A1 | yes (junior a1 + senior re-verification) | pass | /tmp/gc-review/repo/a1.md; /tmp/gc-review/review/junior-review.md |
| A2 MCP wiring + byte-equality | REPO | §4 A2 | yes (junior a2 + senior) | pass | repo/a2.md; npm run test_librechat PASS |
| A3 GC provision path | REPO | §4 A3 | yes (junior a3 + senior) | pass | repo/a3.md |
| A4 template vs runbook §3.4 | REPO | §4 A4 | yes (junior a4 + senior) | pass | repo/a4.md |
| B1 registry publish claim | REPO | §4 B1 | yes (junior b1 + senior) | pass (finding R-09) | repo/b1.md |
| B2 docs defect sweep | REPO | §4 B2 | yes (junior b2 + senior) | pass (findings R-01..R-05) | repo/b2.md |
| B3 guide vs scripts | REPO | §4 B3 | yes (junior b3 + senior) | pass (findings R-07, R-08, R-17) | repo/b3.md |
| B4 runbook §6 matrix | REPO | §4 B4 | yes (junior b4 + senior) | pass (1 detail CORRECTED) | repo/b4.md; junior-review.md |
| C1 secret handling | REPO | §4 C1 | yes (junior c1 + senior) | pass (conditional RISK noted) | repo/c1.md |
| C2 soft-fail inventory | REPO | §4 C2 | yes (junior c2 + senior) | pass (finding R-15) | repo/c2.md |
| C3 GC_PROVISION_DEGRADED | REPO | §4 C3 | yes (junior c3 + senior) | pass (finding R-15) | repo/c3.md |
| C4 MCP token handling | REPO | §4 C4 | yes (junior c4 + senior) | pass (finding R-16) | repo/c4.md |
| D1 coverage map | REPO | §4 D1 | yes — SENIOR SUBSTITUTION (junior failed 2x) | pass | /tmp/gc-review/review/d1-d3.md |
| D2 isolation contract checks | REPO/LIVE | §4 D2, §6 L1 | no — pending L1 execution | not-run (pending) | plan v4 §6 L1 |
| D3 gap-list confirmation | REPO | §4 D3 | yes — SENIOR SUBSTITUTION | pass (15/15 confirmed + 3 new) | review/d1-d3.md |
| WS-DEPLOY-A CapRover inventory | DEPLOYED | §5 | yes (orchestrator) | pass — all apps present, image/override match | /tmp/gc-review/deployed-inventory.md |
| Env value comparison (§5 procedure) | DEPLOYED | §5 | yes (orchestrator) | pass — all MATCH; GC_SKILLS_ENABLED '1' format note closed as MATCH (template ^[01]$) | /tmp/gc-review/expect-verdicts.md; template :187-191 |
| WS-DEPLOY-B authorization audit | DEPLOYED | §5 | attempted (orchestrator) | BLOCKED-HUMAN — MCP bearer is not a Superset-core credential | /tmp/gc-review/deploy-b-inventory.md; TODO.md items 2-4 own it (finding D-02) |
| Registry GETs | DEPLOYED | §5 item 6 | yes | pass-with-finding — /v4/list 200, librechat 404 (= runbook §5 documented state; gap D-01) | deployed-inventory.md; runbook:313-317 |
| Local unit suites (test_librechat, test_superset_ctl, validate_apps, formatter --check) | LIVE | §8 required runs | yes | pass (all rc=0) | team-lead suite results |
| L1 run.sh + tls_check.sh from scratch copy | LIVE | §6 L1 | no | not-run (pending) — REQUIRED RUN still outstanding | plan v4 §6 L1 contract |
| L2 unauth prod probes | LIVE | §6 L2 | yes | pass — 200/HSTS, registrationEnabled:false, 401 trio incl. expired real-secret token (expiry ENFORCED) | team-lead L2 results |
| L3 MCP probe (handshake, tools/list, bounded dataset read) | LIVE | §6 L3 | yes | pass-with-note — 24 tools exact; list_datasets returned real warehouse rows; column cross-check vs WS-DEPLOY-B unavailable (blocked) | team-lead L3 results |
| L4 GC_PROVISION_DEGRADED log grep | LIVE | §6 L4 | no | not-run (pending) | plan v4 §6 L4 |
| WS-LIVE-B guided chat scenario | LIVE | §6, phase 2 | no (by design) | unverified-by-design — checklist ships in report; phase-2 user-gated | plan v4 §6 WS-LIVE-B |
| G2 clef triage batch | process | §7 | no — pending this review | not-run (pending) | findings list ready for triage |
| Report draft + user presentation | process | §11 | no — pending | not-run (pending) | — |
