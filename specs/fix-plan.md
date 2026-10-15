# Fix plan for specs/librechat-mcp.md (DRAFT v3 → v4)

Inputs: Opus review (B1, R1–R10, NITs) and Codex review. D1–D6 stay unchanged. Format per item: **§** sections · **Change** · **Check** · **Conf** · questions (Qn, listed at the end).

## A. Blockers

1. **Description limit (B1, Codex blocker)**
   - §: 5.1, 5.8, 3.5.
   - Change: in §5.8, replace "a `docs`-style section in the template description" with "`instructions.start` (prerequisites) and `instructions.end` (setup steps), plus a link to `specs/librechat-superset.md` (the spike 6.4 output)". Add to §3.5: "`description` ≤ 200 chars (enforced by `validate_apps.js`); all setup text goes in `instructions`."
   - Check: grep the SPEC for "template description" and find no setup content there. §5.1 still lists `npm run validate_apps`.
   - Conf: HIGH.

## B. Validation and URL policy

2. **One validator, run in node; no shell-glob checks (Codex nits, R2)**
   - §: 3.3 step 4, 3.4, 5.2.
   - Change: replace the shell `case` pre-check with a `node -e` pre-check that runs before any file write. It tests every user env var against the **exact §3.4 regexes**, copied verbatim into one JS object in the script. It also applies the URL policy (item 3). On failure it prints the variable name only and exits 1. The post-check stays as is: `configSchema.strict().safeParse`. Add a rule: the §3.4 `validRegex` strings and the script's JS regexes must be identical, and the test asserts this by extracting both from the template.
   - Check: §3.3 has no `case` statement. §5.2 includes "the regexes in the template and the script match" and "each bad value fails before the file is written (the file is absent or unchanged)".
   - Conf: MEDIUM (needs node available before the write; spike 6.1 already covers node).

3. **URL policy (Codex risk "only on placeholders", R3)**
   - §: 3.3 step 4, 3.4, 4.
   - Decision: enforce the policy in the node pre-check on the **resolved env values**, i.e. the same values LibreChat substitutes. Install-time regexes only mirror it. Rules for `LLM_BASE_URL`, `WINDMILL_MCP_URL` and `SUPERSET_MCP_URL`:
     - (a) parse with `new URL()`; a parse failure is an error;
     - (b) no userinfo (`url.username`/`url.password` must be empty);
     - (c) no query parameter named `token`, `api_key`, `apikey` or `access_token` (case-insensitive); otherwise any query and fragment are allowed;
     - (d) the scheme must be `https:`, except `http:` when the hostname matches `^srv-captain--[a-z0-9-]+$`;
     - (e) no `'"\` and no whitespace in the raw string.
   - `PG_MCP_URL` is fixed and exempt. In §3.4, add `(?!.*[?&](token|api_?key|access_token)=)` and `(?![^/]*@)` to the URL regexes as hygiene only.
   - Check: §5.2 has hostile cases `https://u:p@h/x`, `https://h/mcp?token=abc`, `http://example.com/mcp`, and each exits 1. `http://srv-captain--windmill:8000/api/mcp/w/main/mcp` passes.
   - Conf: HIGH for rules a–e; MEDIUM for the hostname pattern (Q1).

4. **Post-check depends on env (R2)**
   - §: 5.2.
   - Change: "Each test case exports the full env for that case before running the script, because the schema may resolve `${VAR}` before checking `url`."
   - Check: the §5.2 text says so.
   - Conf: HIGH.

## C. Spikes: outputs, gates, fallbacks

5. **Gates line per spike (NIT)**
   - §: 6.
   - Change: append "Gates:" to each spike: 6.1 → §3.3 step 4 and §5.2; 6.2 → the pg-mcp service, §5.4, §5.5 Postgres; 6.3 → D1 and the whole api `command`; 6.4 → §5.8 and Superset text in `instructions`; 6.7 → `titleConvo` (item 10).
   - Check: every OPEN spike has a Gates line.
   - Conf: HIGH.

6. **Array-command fallback (R6)**
   - §: 6.3, 3.3, 7 (a D1 note, no new decision).
   - Decision:
     - Primary: YAML array `['sh','-c',<script>]`.
     - If spike 6.3 shows the array or `${…}` mangled, use the fallback: a string `command` of the form `sh -c 'echo <BASE64> | base64 -d | sh'`. `<BASE64>` is the same fixed script, encoded at authoring time. It contains no `$`, quotes or spaces, so CapRover's JSON substitution and quote-splitting leave it intact. `$$cap_*` still appears only in `environment`.
     - The test decodes `<BASE64>` and runs it, so the script stays the single source of truth via a repo file `scripts/librechat-boot.sh` plus an encode step. The test asserts that the decoded text equals the repo file.
   - Spike 6.3 must also check that the command override survives a later image-tag change in the CapRover UI (item 12).
   - Check: §6.3 lists both branches and the persistence check. §5.2 covers the chosen form.
   - Conf: MEDIUM (Q2: `base64 -d` exists in node:24-alpine through busybox; confirm in spike 6.1).

7. **Postgres idle decision rule (R7)**
   - §: 6.2, 3.1.
   - Rule, in this order:
     - (1) If the pinned `crystaldba/postgres-mcp` tag has `/bin/sh`, use `command: ['sh','-c', 'if [ -z "${DATABASE_URI:-}" ]; then echo "pg-mcp disabled"; exec tail -f /dev/null; fi; exec <entry> --access-mode=restricted --transport=sse <host/port flags>']`. `tail -f /dev/null` replaces `sleep infinity`, which busybox may lack.
     - (2) Otherwise, use `python:<pinned>-slim` with the same guard plus `pip install --no-cache-dir postgres-mcp==<pinned>` at start. This needs PyPI access at boot; record it as a known limitation.
     - (3) If neither works, record the result and stop for a decision; do not ship.
   - Check: §6.2 states the rule. §5.4 tests whichever branch is chosen.
   - Conf: LOW for branch 2 (Q3).

8. **Superset spike outputs (R5, Codex "identity spike too narrow")**
   - NOTE (verified later, 2026-10-14): the `MCP_DISABLED_TOOLS` item in (a)
     was never valid for 6.1.0 — the setting does not exist in that tag and is a
     silent no-op. Superseded by `specs/librechat-superset.md` and
     `docs/librechat-integrations.md` §1, which were corrected after a source
     audit of the `6.1.0` tag. This entry is kept as a historical record of what
     was asked for, not as current guidance.
   - §: 6.4, 2 (Superset), 4.
   - Change: spike 6.4 must deliver:
     - (a) `specs/librechat-superset.md`: the exact patch pin (≥6.1.0) and a `superset_config.py` snippet: `MCP_AUTH_ENABLED`, `MCP_JWT_ALGORITHM="HS256"`, `MCP_JWT_SECRET`, `MCP_JWT_ISSUER`, `MCP_JWT_AUDIENCE`, `MCP_REQUIRED_SCOPES`, `MCP_DISABLED_TOOLS`, `MCP_RBAC_ENABLED=True`;
     - (b) `scripts/superset_mint_mcp_token.py`: Python stdlib only (hmac/hashlib/base64/json), args `--sub --iss --aud --scopes --days`; it never prints the secret and reads it from env `MCP_JWT_SECRET`;
     - (c) the claim contract: the scope claim name and format (`scope` space-string vs `scopes` list), plus the `iss`/`aud` requirements;
     - (d) the identity mapping: how a JWT maps to a FAB user (`sub` = username? fallback/dev user?), verified with one Alpha and one Gamma user;
     - (e) a 1-year `exp` accepted and an expired token returning 401;
     - (f) how `superset mcp run` is deployed: a separate CapRover app built from the user's Superset image plus `apache-superset[fastmcp]`, sharing `superset_config.py` and the metadata DB.
   - Check: both files exist, and §5.8 references (c)–(e) as preconditions.
   - Conf: MEDIUM (Q4, Q5).

## D. Least privilege and identity

9. **Windmill least-privilege recipe (R4, Codex risk)**
   - §: 4, 5.5, 3.5.
   - Decision:
     - Create a dedicated **non-admin** user `librechat-agent` in a test workspace, plus folder `f/agent` with that user as writer.
     - Token = one scoped token per use case, using the `{domain}:{action}:{path}` scopes for `f/agent/*`: scripts write, flows write, schedules write, jobs run, jobs read.
     - Use the read-only variant (Read-only toggle) when the agent must not create anything.
     - When generating the MCP URL, limit MCP tool exposure to folder `f/agent`.
   - §5.5 then runs `createScript`/`runScriptByPath`/`createSchedule`/`getJobLogs` with this token. It checks that `deleteScriptByPath` is rejected and that creating outside `f/agent` is rejected.
   - Check: §4 lists the exact scope strings. §5.5 names the token used for each step.
   - Conf: LOW for the exact scope domain names (Q6).

10. **Title generation fallback (Codex risk, NIT)**
    - §: 3.3 step 1, 6.7.
    - Change: default `titleConvo: false`. Spike 6.7 tests title generation with `gpt-oss-120b`. Only if it works, set `titleConvo: true` and `titleModel: 'current_model'`.
    - Check: §3.3 shows `titleConvo: false` unless §6.7 records a pass.
    - Conf: HIGH.

## E. Ops (new §3.6 "Operations")

11. **Backup policy (R10, Codex risk)**
    - §: new 3.6, 3.5 `end`.
    - Policy:
      - Before every upgrade, and on a schedule the operator chooses, run `docker exec $(docker ps -qf name=srv-captain--<app>-mongodb) mongodump -u librechat -p <pw> --authenticationDatabase admin --archive --gzip > librechat-<date>.archive.gz`.
      - Tar the `-uploads` and `-images` volumes. Logs are not backed up.
      - Store `CREDS_KEY`, `CREDS_IV`, `JWT_*` and the Mongo password with the backup; without the `CREDS_*` keys, the restored user API keys are unreadable.
      - Restore = `mongorestore --archive --gzip --drop`, then the volumes.
    - Check: §3.6 has the commands. A new acceptance item §5.9 covers backup, wipe, restore, login, an old conversation, and a stored user key that still works.
    - Conf: MEDIUM (Q7).

12. **Upgrade and rollback policy (R6/R10, Codex risk)**
    - §: 3.6.
    - Policy:
      - LibreChat upgrade = take a backup (item 11), then change the image tag in the CapRover app (Deployment → deploy via image name). The one-click variable is install-only.
      - Rollback = redeploy the previous tag. If the new version ran migrations, restore the pre-upgrade dump.
      - Mongo: only patch upgrades within `8.0.x` in v1. A major upgrade is out of scope and needs the FCV procedure.
      - Spike 6.3 must confirm the command override persists across a tag change.
    - Check: §3.6 states the policy. A new acceptance item §5.10 covers v0.8.8 → newer patch → rollback to v0.8.8 with a restore, with no data loss.
    - Conf: MEDIUM.

13. **Mongo password caveat (R8)**
    - §: 3.1, 3.5 `end`.
    - Change: "`MONGO_INITDB_ROOT_*` applies only on the first init. Changing `$$cap_mongo_password` later breaks `MONGO_URI`; to rotate, run `db.changeUserPassword` first, then update `MONGO_URI`."
    - Check: the text is present in both places.
    - Conf: HIGH.

14. **Env secrets as an accepted risk (R9)**
    - §: 4.
    - Change: "All secrets (`CREDS_*`, `JWT_*`, Mongo password, MCP tokens, DSN, LLM key) are plain text in the CapRover app config and `docker service inspect`. Anyone with CapRover admin or Docker socket access can read them. This is accepted for v1."
    - Check: the line is present.
    - Conf: HIGH.

15. **HTTPS before first login (R1)**
    - §: 3.5 `start`/`end`, 5.3.
    - Change: "Enable HTTPS for the app in CapRover before the first login; with `NODE_ENV=production`, secure cookies are dropped over http and login loops." Add to §5.3: "login over http fails and over https works".
    - Check: the text is present and §5.3 is updated.
    - Conf: MEDIUM (Q8).

16. **Test runner and logo (R10)**
    - §: 5.1, 5.2.
    - Change:
      - Add the npm script `"test_librechat": "sh scripts/test_librechat_config.sh"`. It requires docker and is not part of `validate_apps`.
      - Extraction uses node plus the repo `yaml@^1` dependency, not yq.
      - The logo is `public/v4/logos/librechat.png`, taken from the LibreChat repo `client/public/assets/logo.svg` and converted to PNG (MIT). §5.1 records the source.
    - Check: §5.1 and §5.2 name the command, prerequisites and logo source.
    - Conf: MEDIUM (Q9).

## F. NITs (all HIGH)

17. §2: pick one line ref for `configSchema` (verify `:3125` vs `:3841` at e1dfc10) and delete the repeated WORKDIR/CMD/port bullet (§2:27).
18. §3.4: write `$$cap_mongo_version` as `/^[\w.-]{1,32}$/`.
19. §4, §5.8: replace "Gamma/Viewer" with "Gamma (or a named custom read role)".
20. Status line: "D1–D6 resolved".
21. §3.1: verify that the `mongo:8.0.20` tag exists before pinning, or note "verify in PLAN".

## Questions

- Q1: Allow `http` only for `srv-captain--*`, or also for bare internal hostnames such as `localhost` or a Tailscale IP? (The plan says only `srv-captain--*`.)
- Q2: Is the base64 fallback acceptable under D1 ("inline `sh -c` script"), or should a failed spike 6.3 reopen D1?
- Q3: If postgres-mcp has no shell, do you accept a pip install at boot (needs network), or should Postgres MCP move to v2?
- Q4: Does Superset 6.1 map JWT `sub` to a FAB username, or use a fixed `MCP_DEV_USERNAME`-style setting? This decides whether Alpha and Gamma can share one MCP process.
- Q5: Should the minting script live in this repo (`scripts/`) or in the Superset deployment repo?
- Q6: What are the exact Windmill scope domains for schedules and job runs (`schedules:write`, `jobs:run`?)? Do you want the agent confined to a folder or a whole dedicated workspace?
- Q7: Is a manual backup procedure enough for v1, or do you want a scheduled backup sidecar?
- Q8: Do you have evidence LibreChat v0.8.8 sets `secure` cookies based on `NODE_ENV` or on the `DOMAIN_SERVER` scheme? If it uses the scheme, the fix becomes "use https in `DOMAIN_*`" only.
- Q9: Should `test_librechat` run in a GitHub Actions workflow (docker is available there), or stay local-only?
