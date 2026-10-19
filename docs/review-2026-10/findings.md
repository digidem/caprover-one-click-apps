# Consolidated findings — LibreChat/CapRover/GC integration review (phase 1)

Date 2026-10-17. Layers: REPO / DEPLOYED / LIVE. Severity: CRITICAL/HIGH/MED/LOW/INFO. Every finding carries evidence and a one-line recommendation.

Status note (2026-10-19): R-01..R-08, R-17, R-18 and L-03 were fixed in commit bf8fd11 on this branch; R-14 and the remaining MEDs are tsk-tracked (gc-review-12/15) and user-gated. The e2e ownership-refusal check (4th cross-role check) can skip vacuously when the writer chart is absent (readonly_checks.py:103) — tracked with gc-review-15 test hardening.

## REPO layer

| id | sev | finding | evidence | recommendation |
|---|---|---|---|---|
| R-01 | LOW | Runbook targets app `librechat`; production app is `chat` | docs/production-runbook.md:3 vs :90,:239; docs/librechat-integrations.md:533 | Rename target to `chat` in line 3 |
| R-02 | LOW | Duplicate `### 3.3` headings (first empty); §3.1 heading ends mid-sentence | docs/production-runbook.md:211,213; :158-159 | Renumber and join heading text |
| R-03 | LOW | Dead internal section refs | docs/production-runbook.md:42 (§6.1), :173 (§6.6) | Point at §2.5 step 1 / §7 item 6 |
| R-04 | LOW | Guide: unnumbered heading breaks 1.x sequence; executable prose inside bash fence; wrong spike-file glob | docs/librechat-integrations.md:43; :54-57; :7 | Number heading; `# `-prefix the prose; name specs/librechat-superset.md |
| R-05 | LOW | Duplicated clause in one sentence | docs/gc-analytics-ui-recipe.md:15 | Delete trailing clause |
| R-06 | LOW | Spec claims §3.4 URL regexes are "copied verbatim into one JS object"; implementation validates URLs via urlOk rules instead (stricter: http only to srv-captain-*) | specs/librechat-mcp.md:114 vs scripts/librechat-boot.sh:49-64 | Reword spec:114 to describe urlOk; note the stricter rule |
| R-07 | MED | Guide install line pins PyJWT; no repo script uses it (mint is stdlib-only) | docs/librechat-integrations.md:18 vs scripts/superset_mint_mcp_token.py:12-19 | Drop the PyJWT pin or mark it optional |
| R-08 | LOW | --days defaults inconsistent (script 365, guide example 30, runbook 90); --sub default librechat-agent vs prod svc-chat-mcp | scripts/superset_mint_mcp_token.py:26,30; runbook:147,171; guide:55 | State the production flags explicitly in runbook §3.1 |
| R-09 | MED | Registry publish to the operator nginx (167.172.33.4) has no in-repo automation; publish-from-actions.sh is dead code; mirror step is manual and unowned | deploy.yml:39-42; publish-from-actions.sh:45-89 (zero workflow callers); runbook:313-317 | Document the mirror step's owner/procedure in §5 or script it in phase 2 |
| R-10 | MED | JWT wrong-key/expired rejection untested in repo harness | test/superset-e2e (grep expired/wrong: zero hits); run.sh:83-92 asserts no-bearer only | Add wrong-key + expired-token cases to run.sh checks |
| R-11 | MED | Token minting untested; expiry has no reminder automation beyond prose | scripts/superset_mint_mcp_token.py (no test); runbook:371-374 | Add a mint round-trip test; add expiry date to a monitored calendar (TODO item 5) |
| R-12 | LOW | sync_librechat_boot.js untested directly (its output byte-equality IS asserted) | scripts/sync_librechat_boot.js:40-50; test_librechat PASS | Acceptable; note only |
| R-13 | LOW | CapRover deploy path external to repo, no test | runbook:106 (rastro_caprover.py) | Accept as external dependency; record digest checks (done) |
| R-14 | HIGH | Disaster-recovery unproven: MongoDB dump/volume restore (§4) and Superset metadata backup (§4.2) never exercised | runbook:287-308; no test exists | Schedule a restore drill in phase 2 (highest-value fix) |
| R-15 | MED | Soft-fail degradation detectable only via stderr marker; no runtime consumer; state-vs-ACL mismatch prints no marker | scripts/librechat-boot.sh:701,:810; c2 item E; c3 consumer grep | Phase 2: surface GC_PROVISION_DEGRADED via /api/config or a health sidecar; add state/ACL consistency marker |
| R-16 | LOW | pg-mcp serves unauthenticated SSE on 0.0.0.0:8000 inside the CapRover network | public/v4/apps/librechat.yml:69-78 | Note only: mitigated (notExposeAsWebApp, restricted mode, SELECT-only role); OFF in prod |
| R-17 | LOW | Clearing only SUPERSET_MCP_TOKEN leaves a headerless superset MCP entry (docs describe URL-clear only) | scripts/librechat-boot.sh:96-106; guide §6 :454-457 | Add token-only-rotation case to guide §6 |
| R-18 | INFO | Runbook §6 matrix rows lack dates (only R1 dated 2026-10-15, R4 "not yet true") | docs/production-runbook.md:342-351 | Add completion dates as rows are discharged |
| R-19 | MED | e2e harness cold-start flakiness: run.sh web wait budget (40x5s=200s) too short for cold Superset init; superset-mcp races web init and exits 1 (SQLAlchemyError); mcp-writer healthcheck probes stock :8088 while serving :5009 so it stays "unhealthy" | /tmp/gc-review/l1-results.md (cold fail) vs /tmp/gc-review/l1-retry.md (warm PASS); docker ps/inspect 2026-10-17 | Raise web wait to ~60x5s, add depends_on/restart for superset-mcp, override writer healthcheck in compose |

## DEPLOYED layer

| id | sev | finding | evidence | recommendation |
|---|---|---|---|---|
| D-01 | MED | Template `librechat` absent from live registry (/v4/apps/librechat 404) — consistent with runbook §5's documented current state and §6 R4 "not yet true"; not doc-reality drift; gap = unfinished publish | /tmp/gc-review/deployed-inventory.md registry checks; runbook:313-317,:345 | Complete the publish (dist/ to operator nginx or CNAME cutover) with the §5 content-match check first |
| D-02 | MED | Admin-side authorization audit BLOCKED-HUMAN: chat-mcp ten-permission check, grant trim list, RLS inventory, Gamma contents (MCP bearer is not a Superset-core API credential) | /tmp/gc-review/deploy-b-inventory.md; ~/javari-ops/TODO.md items 2-4 | Execute TODO items 2-4 in the Superset console; re-run read test after trimming |
| D-03 | INFO | execute_sql appears in the prod tools/list exposed to the agent identity; tool listed ≠ callable (local harness asserts role-level denial); admin-side permission re-check pending | L3 tool list vs test/superset-e2e/agent_checks.py; TODO item 3 | Fold into D-02 console check: confirm chat-mcp lacks execute_sql permission |
| D-04 | INFO | Prod env matches repo on every compared key: ALLOW_REGISTRATION=false, GC_SKILLS_ENABLED='1' (valid per template ^[01]$, deliberate enable; default '0'), PG_MCP_ENABLED='0' (=default), superset MCP via public URL (=template's own example shape), superset-mcp image sha256:113dab… + ownercheck patch + override + 1.5GiB | /tmp/gc-review/expect-verdicts.md; public/v4/apps/librechat.yml:178-191,:160-168 | None — deployed-vs-repo equivalence holds on all verifiable keys |

## LIVE layer

| id | sev | finding | evidence | recommendation |
|---|---|---|---|---|
| L-01 | PASS | Unauth prod edge probes: chat / 200 + HSTS; registrationEnabled:false; /mcp 401 no-bearer, wrong-key 401, expired real-secret 401 (expiry ENFORCED — stronger than the planned dummy-secret limitation) | team-lead L2 results 2026-10-17; runbook:90-94 matrix row re-verified | None |
| L-02 | PASS | MCP probe: initialize 200 (stateless), tools/list = 24 exactly matching runbook §2.5 (2026-10-16); bounded read list_datasets returned real warehouse records (rastro_diag_dia, database Rastro) → warehouse connectivity + permitted retrieval established | team-lead L3 results 2026-10-17 | Dataset-column cross-check vs WS-DEPLOY-B REST metadata not possible (D-02 blocked); runbook record served as the independent expectation |
| L-03 | INFO | /api/config mcpServers returns {} vs runbook :93 documented literal "null" (both mean "not exposed") | runbook:93; L2 result | One-word doc fix |
| L-04 | PASS | All six required runs executed: npm run test_librechat (incl. GC matrix), test_superset_ctl, validate_apps, formatter --check (all rc=0); run.sh ALL CHECKS PASSED on warm retry (REST helper 24/24, memory bounded +2.6 MiB/200 calls, chart/dashboard flows); tls_check.sh TLS CHECKS PASSED. Cold start of run.sh failed once → R-19 | /tmp/gc-review/l1-retry.md, /tmp/gc-review/l1-tls.md, suite rc outputs 2026-10-17 | None beyond R-19 |
| L-05 | UNVERIFIED-BY-DESIGN | chat→LLM end-to-end chain (LibreChat service + LLM round-trip + real user turn) — no test at any layer; harness has no LibreChat service; WS-LIVE-B execution is phase 2 | d1-d3.md row 11 | Execute WS-LIVE-B checklist after phase-1 report, user-gated |

## BLOCKED-HUMAN items (never excludable, owned)

| item | owner | next step |
|---|---|---|
| WS-DEPLOY-B items 1-6: chat-mcp ten-permission check, dataset/database grant trim list, RLS inventory, Gamma contents | ~/javari-ops/TODO.md items 2-4 (human, Superset console) | Execute console checks; re-run LibreChat read test (list + get data on Gasolina) after trimming |
| D-03 follow-up: confirm chat-mcp lacks execute_sql permission | same console pass | Check role permission list while in the role editor |
| L4: GC_PROVISION_DEGRADED in api logs since last redeploy | orchestrator via CapRover dashboard logs (no read-only API path established) | Grep api logs for the marker |

## Unverified-surface list (UNVERIFIED-BY-DESIGN, phase 1)

1. chat→LLM end-to-end chain (LibreChat service, LLM round-trip, real user turn) — WS-LIVE-B checklist ships in the report; execution phase 2, user-gated.
2. In-container provisioned skills/ACL state inside the chat container/Mongo (no read-only external path).
3. Admin-side Superset authorization surface (roles/grants/RLS/Gamma) — BLOCKED-HUMAN above.
4. Real edge TLS with public CA beyond the observed 200/401 responses (harness covers self-signed localhost only).
5. superset-mcp foreign-chart write refusal on prod (last proven 2026-10-16; not re-proven by read-only review).

## Layer verdicts (phase 1)

- REPO: PASS with findings — integration coherently built; defects documentation-level (R-01..R-08), security-hygiene gaps R-10/R-11, harness flakiness R-19, one HIGH disaster-recovery gap (R-14).
- DEPLOYED: PASS on all verifiable keys (D-04); open items D-01 (registry publish) and D-02 (authorization audit, BLOCKED-HUMAN), both known and owned.
- LIVE: Superset/MCP/REST chain PASS (L-01, L-02, L-04); chat→LLM chain UNVERIFIED-BY-DESIGN (L-05).
- Mission Q1 (production matches repo intent): YES on every verifiable key. Mission Q2 (end-to-end for a chat user): warehouse-side chain verified read-only; full chat turn UNVERIFIED-BY-DESIGN pending WS-LIVE-B (phase 2).
