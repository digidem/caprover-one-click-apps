# Suggested answers to fix-plan questions

Q1 is settled by the user: https only, except `srv-captain--*` hosts, which may use http. Apply it as written in fix-plan item 3.

## Q8: HTTPS and cookies, following the repo pattern

**Repo pattern found:**
- `public/v4/apps/rastro.yml:110–111`: the `end` instructions have numbered steps. Step 2 is "On app `$$cap_appname`: enable HTTPS and Force HTTPS", followed by one sentence explaining why: the API refuses access without HTTPS, and the viewer does not send credentials over HTTP.
- `rastro.yml:71`: the app enforces this itself (`RASTRO_REQUIRE_HTTPS: '1'`).
- `rastro.yml:106`: `start` lists prerequisites, including wildcard DNS.
- `comapeo-cloud.yml` and `README.md` have no HTTPS or cookie pattern.
- The rastro pattern, in short: secure by default, no option to turn it off, and an explicit "enable HTTPS + Force HTTPS" step in `end` with the reason.

**Recommendation:**
- Keep `NODE_ENV=production`.
- Do NOT set or expose `SESSION_COOKIE_SECURE`, so secure cookies stay on (csrf.ts:21-35).
- Add to `start`: "The CapRover wildcard DNS must be set up (HTTPS needs it)."
- Wording for `end`, step 1: "1. On app `$$cap_appname`: enable HTTPS and Force HTTPS BEFORE the first login. LibreChat runs in production mode, so login cookies are sent only over HTTPS; over plain HTTP, login fails or loops."
- Custom-domain step: "If you add a custom domain, enable HTTPS on it and set `DOMAIN_CLIENT` and `DOMAIN_SERVER` to `https://<your-domain>`."
- §5.3: "Login over HTTPS works. Over HTTP it fails, which is expected."
- §4: "`SESSION_COOKIE_SECURE=false` is not supported."

**Risk if wrong:** if we instead add an override for http, admins may run login over plain HTTP, and session cookies could be stolen on the network.

**Plain language:** LibreChat only hands out its login "ticket" over a secure connection. So the first thing to do after install is to switch on HTTPS in CapRover, the same way the Rastro app asks. If you skip it, the login page just keeps sending you back.

## Q2: Fallback if the array `command` fails

**Recommend:** accept the base64 fallback as a sub-variant of D1, without reopening D1. The script is still inline, fixed and in the template; only its encoding changes. Keep the readable copy in `scripts/librechat-boot.sh`, and have the test assert that the encoded and readable copies match.

**Risk if wrong:**
- If we reopen D1 instead, we must build and publish our own image. That brings a registry, an update chore and supply-chain trust, which D1 rejected.
- If we accept base64 but skip the match test, the readable script and the deployed script can drift apart silently.

**Plain language:** the startup recipe may get scrambled when CapRover copies it. If so, we pack it in a sealed envelope (base64) that CapRover cannot scramble, and the container opens it at start. The recipe is the same; only the packaging changes.

## Q3: postgres-mcp image without a shell

**Recommend:** check first; it probably has one, since the image is Python-based. If it has no shell, move Postgres MCP to v2 rather than installing it from PyPI at every boot. Superset is the primary integration (D4), and Postgres is optional.

**Risk if wrong:**
- Installing at boot makes every restart depend on PyPI being reachable. It also pulls whatever the package's dependencies resolve to at that moment, which is weak supply-chain pinning and gives non-reproducible deploys.
- Dropping Postgres loses one optional feature for v1.

**Plain language:** the database helper needs a tiny "on/off switch" script inside its container. If that container cannot run the switch, the alternative is downloading the helper fresh from the internet on every start. That is fragile, so we would rather postpone this helper than ship it shaky.

## Q4: Superset JWT identity mapping

**Recommend:** treat this as the top item in spike 6.4, and assume nothing until it is tested. Plan for one MCP process and one token per identity: an Alpha token for writes and a Gamma token for read-only. Two LibreChat entries (`superset` and `superset-readonly`) are only needed if both are wanted at once; v1 should ship one entry and document how to switch tokens. If the spike shows Superset ignores `sub` and uses one fixed user per process, then each identity needs its own MCP process (two CapRover apps), and §5.8's Alpha-vs-Gamma test becomes "two processes".

**Risk if wrong:** if we assume per-token identity but Superset uses a fixed user, every chat user acts as that one user, possibly Admin. That means the AI could edit or delete dashboards that the token holder should not touch.

**Plain language:** when the AI talks to Superset, Superset must know "who" is asking, so it applies the right permissions. We need to test whether Superset reads the name on the AI's pass or treats every pass as the same person. The answer decides whether one connection is enough or we need one per role.

## Q5: Where the token minting script lives

**Recommend:** in this repo, at `scripts/superset_mint_mcp_token.py`. Use Python stdlib only, with the secret read from env. Link it from `instructions.end` via its GitHub raw URL. Users of this one-click app have no other repo, and this repo is where the matching LibreChat side is documented and tested.

**Risk if wrong:** in a separate repo, the script and the template drift: claim names and scopes change in one place and not the other, and tokens stop working. Keeping it here makes the §5.8 test exercise the exact script users run.

**Plain language:** the AI needs a signed pass to enter Superset, and this small script prints that pass. Keeping the script next to the app it serves means it gets tested together with the app and does not get lost.

## Q6: Windmill least-privilege scope

**Recommend:**
- Use a dedicated folder (`f/agent`) inside the user's existing workspace, with a dedicated non-admin user.
- Use folder-scoped tokens, and limit MCP tool exposure to that folder.
- Exact scope domain names (`schedules`, `jobs`, `flows`, ...) are not confirmed. Spike them on the test Windmill (≥1.484.0) by generating a token in the UI with each scope ticked and reading the token's scope list. Then write the real strings into §4.
- A whole dedicated workspace is safer, but it cannot reach the user's existing scripts and resources, which usually defeats the purpose. Offer it as the "strict" option in the docs.

**Risk if wrong:**
- Too broad (workspace-wide write): the AI can overwrite or schedule any script, including production jobs.
- Too narrow or wrong scope names: the §5.5 tests fail, and users see confusing "forbidden" errors.

**Plain language:** we give the AI its own drawer (a folder) in Windmill and a key that only opens that drawer. It can create and run automations there, but not touch anything else. We still need to check the exact labels Windmill uses for "schedules" and "run jobs" before writing them down.

## Q7: Backups for v1

**Recommend:** a manual, documented procedure for v1 (mongodump + volume tar + secrets record, as in fix-plan item 11), plus the §5.9 restore test. Point users to the CapRover server's existing backup tooling, if any. A scheduled sidecar can come in v2. It needs somewhere off-server to send backups, plus retention and alerting, which is a design question on its own.

**Risk if wrong:** a manual procedure gets skipped, so a disk failure or bad upgrade can lose all chats and stored keys. The `end` instructions must say this plainly, and the upgrade policy makes "back up first" a mandatory step.

**Plain language:** for now, backups are a short set of commands an admin runs, especially before every upgrade. Automatic scheduled backups are useful, but they need a decision about where copies are kept off the server, so they come in the next version.

## Q9: Where `test_librechat` runs

**Recommend:** both. Keep it runnable locally (`npm run test_librechat`). Also add a GitHub Actions job that runs it only when `public/v4/apps/librechat.yml` or `scripts/librechat-boot.sh` changes. GitHub runners have docker, so pulling the pinned image there is fine. The job should not run on every PR, to keep other app changes fast.

**Risk if wrong:**
- Local-only: someone edits the template, forgets to run the test, and a broken startup script ships to every new install.
- CI on every PR: slower CI and image-pull flakiness that blocks unrelated changes.

**Plain language:** the test checks that LibreChat's startup recipe still produces a valid configuration. Running it automatically on GitHub whenever the LibreChat files change means mistakes get caught before anyone installs a broken app.
