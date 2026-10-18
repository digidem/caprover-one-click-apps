# Integration review — LibreChat / CapRover / Guardian Connector (phase 1)

Date: 2026-10-17 · HEAD `4618b97` (branch `runbook-accuracy`) · Zero writes to production and to the repo (phase-1 contract).
Method: senior (Opus 5.5) plan + adversarial review · junior (deepseek-4.1-flash via opencode) 15-brief inventory + audits · codex gpt-6.1-sol (low) plan gate ×4 rounds → AGREE · clef typed gates G1/G2/G3 logged in `/tmp/gc-review/clef-log.md` · xerj evidence.

## Verdicts

| Layer | Verdict |
|---|---|
| REPO | PASS with findings — coherent integration; doc-level defects, test-hygiene gaps, one HIGH: DR unproven |
| DEPLOYED | PASS on every verifiable key — prod matches repo intent (images, env, overrides, patch) |
| LIVE | Superset/MCP/REST chain PASS (24 tools exact, bounded warehouse read OK, expiry enforced) · chat→LLM chain UNVERIFIED-BY-DESIGN in phase 1 |
| Mission Q1: does prod match repo intent | YES on every verifiable key |
| Mission Q2: does chat→warehouse work end-to-end | Warehouse-side chain verified read-only; full chat turn = phase-2 guided scenario (user-gated) |

## What was verified (highlights)

- **Deployed equivalence (D-04)**: all 5 apps present; superset-mcp = `communityfirst/superset-mcp@sha256:113dab…` with chart-ownership patch, override command, healthcheck, 1.5 GiB; chat env matches template on all compared keys (`ALLOW_REGISTRATION=false`, `GC_SKILLS_ENABLED='1'` valid per `^[01]$`, `PG_MCP_ENABLED='0'` = default).
- **LIVE prod probes**: chat edge 200 + security headers; registration off; JWT gate fails closed on no-bearer / wrong-key / **expired real-secret token (expiry ENFORCED)**; MCP stateless init; tools/list = **24, exactly the runbook set**; `list_datasets` returned real warehouse records (`rastro_diag_dia`, Rastro DB).
- **Local e2e (isolated scratch copy, local Docker socket, env -i)**: run.sh **ALL CHECKS PASSED** (REST 24/24, memory bounded +2.6 MiB/200 calls, chart+dashboard flows, ownership denial) after one cold-start failure (→ R-19); tls_check **PASSED**.
- **Local suites**: test_librechat (incl. GC matrix), test_superset_ctl, validate_apps, formatter --check — all PASS.

## Findings (22 rows; zero CRITICAL)

Full table: `/tmp/gc-review/review/findings-table.md`. Top items:

| id | sev | one-line | recommendation |
|---|---|---|---|
| R-14 | HIGH | Mongo restore + Superset metadata backup never exercised | Restore drill = first phase-2 item (clef risk score: "Major" 0.75) |
| R-09/D-01 | MED | librechat template NOT in live registry (404); publish automation dead code, mirror manual/unowned | Complete publish + document owner |
| R-10/R-11 | MED | JWT wrong-key+expired untested in harness; mint round-trip untested | Add both tests (expiry itself PROVEN live today) |
| R-19 | MED | Harness cold-start flaky: 200s web wait too short; superset-mcp init race (exit 1); writer healthcheck probes wrong port | 3-line compose/run.sh hardening |
| R-15 | MED | GC_PROVISION_DEGRADED has no runtime consumer | Surface via /api/config or health sidecar |
| R-07 | MED | Guide pins PyJWT; script is stdlib-only | Doc fix |
| D-02 (+D-03) | MED | Admin-side Superset authz audit BLOCKED-HUMAN; execute_sql listed-but-(to-be-confirmed)-not-callable | Human console pass = javari-ops TODO items 2-4 + execute_sql check |
| R-01..R-06, R-08, R-17, R-18, L-03 | LOW | Doc defects (app name, duplicate 3.3, dead refs, spec wording, defaults) | Ten one-line doc fixes |

## BLOCKED-HUMAN (owned, never excluded)

- Superset console pass (roles/grants/RLS/Gamma + execute_sql permission) → `~/javari-ops/TODO.md` items 2-4; re-run read test after trimming.
- L4 log grep for GC_PROVISION_DEGRADED → CapRover dashboard (no read-only API).

## Unverified surfaces (UNVERIFIED-BY-DESIGN, phase 1)

1. chat→LLM end-to-end (real user turn) — WS-LIVE-B checklist below, execution user-gated.
2. In-container provisioned skills/ACL state (no read-only external path).
3. Admin-side Superset authz surface (see BLOCKED-HUMAN).
4. Real edge TLS beyond observed 200/401 (harness covers self-signed localhost).
5. Foreign-chart write refusal on prod (last proven 2026-10-16).

## WS-LIVE-B checklist (phase 2, user-gated; creates exactly one conversation record)

Chat asks: "list my Superset dashboards and show the data behind one Gasolina chart" → success = grounded answer, visible read-only tool calls, no permission errors. Double clef G3 before running.

## Ways forward (priority order; clef G2 + senior agree)

1. **Restore drill (R-14, HIGH)** — rehearse Mongo restore + Superset metadata backup on scratch. Biggest real risk.
2. **Human console pass** (~30 min, TODO items 2-4 + execute_sql) — closes the authz audit.
3. **Phase-2 doc batch** — ten one-line fixes + L-03 null→{} + R-06/R-07/R-08.
4. **Registry publish (D-01/R-09)** — finish publish, document mirror owner.
5. **Test hardening (R-10/R-11/R-19/R-15)** — JWT cases, mint test, harness cold-start, degraded-marker consumer.
6. **WS-LIVE-B guided scenario** — closes the last UNVERIFIED surface (one conversation record, user-gated).
7. **Token expiry calendar (~2027-01-11)** — monitored reminder (TODO item 5).

## Artifacts

Plan v1-v4 + codex gates: `/tmp/gc-review/review-plan-v4.md`, `codex-plan-gate*.json` · findings: `review/findings-table.md` · junior review: `review/junior-review.md`, `review/d1-d3.md` · ledger: `review/ledger.md` · deployed inventory (redacted): `deployed-inventory.md`, `expect-verdicts.md`, `deploy-b-inventory.md` · probe outputs: `l1-retry.md`, `l1-tls.md` · clef log: `clef-log.md` · tsk board: gc-review-1..15.
