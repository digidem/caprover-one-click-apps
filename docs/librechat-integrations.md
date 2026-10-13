# LibreChat one-click app — integrations guide

Setup for the optional MCP integrations of
[`public/v4/apps/librechat.yml`](../public/v4/apps/librechat.yml):
Postgres (read-only), Windmill (dedicated workspace), Superset (one process
per role). Commands were tested as written; see
`specs/spike-*.md` in the repo for the evidence.

## 1. Superset MCP (primary integration)

Superset ≥ 6.1.0. Exact pins (both required):

```bash
uv pip install "apache-superset[fastmcp]==6.1.0" "flask-caching==2.3.0" "fastmcp==3.1.0" PyJWT
```

Config (superset_config.py) block:

```python
MCP_AUTH_ENABLED = True
MCP_JWT_ALGORITHM = "HS256"
MCP_JWT_SECRET = os.environ["MCP_JWT_SECRET"]
MCP_DEV_USERNAME = "alpha"   # the Superset user whose permissions apply
MCP_REQUIRED_SCOPES = "mcp:read"
MCP_JWT_ISSUER = "superset"
MCP_JWT_AUDIENCE = "superset"
MCP_DISABLED_TOOLS = [...]   # drop tools the role must not use
MCP_RBAC_ENABLED = True
```

The token `sub` is ignored (spike 6.4); the process's `MCP_DEV_USERNAME`
defines the acting user. One process per role.

Mint a token:

```bash
MCP_JWT_SECRET=... python3 scripts/superset_mint_mcp_token.py --sub alpha --scopes 'mcp:read mcp:write' --days 30
--days 30 (short-lived) or --days 365 (spike 6.4: accepted)
```

### 1.1 Read-only role (option)

A default Gamma can write Dashboards and Charts (spike 6.4), so read-only
needs a custom role: `can_read` on Dashboard, Chart and Dataset only, and set
`MCP_DISABLED_TOOLS = ["execute_sql", "update_chart", "create_virtual_dataset"]`.

### 1.2 Run as a service

Start `superset mcp run --host 0.0.0.0` and document
MCP_DEV_USERNAME per process. Superset 6.1.0 ships no systemd unit; document
a container or systemd unit per role process on the Superset host.
MCP endpoint: `http://<superset-host>:5008/mcp`


## 2. Windmill (dedicated workspace, D11)

Windmill >= 1.484.0. The agent gets its own workspace `librechat-agent` with a
non-admin user as its only member, because (spike 6.6) a folder-scoped token's
schedule can run a script outside the folder; the workspace is the boundary.

Token scopes that work with the MCP endpoint (spike 6.6):

```json
["mcp:endpoints:listScripts,getScriptByPath,createScript,updateScript,runScriptByPath,listSchedules,getSchedule,createSchedule,updateSchedule,listJobs,getJob,getJobLogs",
 "mcp:scripts:/*", "mcp:flows:/*"]
```

The endpoint ignores API domain scopes (scripts:write:... gets 403). Keep
deleteScriptByPath and deleteScriptByHash out of the endpoint list: both are
admin-only and rejected for the non-admin token.

In LibreChat, set the api env:

    WINDMILL_MCP_URL=http://srv-captain--windmill:8000/api/mcp/w/librechat-agent/mcp
    WINDMILL_MCP_TOKEN=<the token>

## 3. Postgres MCP (read-only)

Create a SELECT-only role in the target database:

    CREATE ROLE librechat_reader LOGIN PASSWORD '...';
    GRANT CONNECT ON DATABASE yourdb TO librechat_reader;
    GRANT USAGE ON SCHEMA public TO librechat_reader;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO librechat_reader;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO librechat_reader;

Set the DSN on the `-pg-mcp` app (DATABASE_URI), redeploy, then set
PG_MCP_ENABLED=1 on the api app and redeploy (order matters; see the install
instructions). The DSN never enters the api container.

## 4. Backups (v1, manual)

Back up before every upgrade. In CapRover set Instance Count = 0 on the api
app (no writes), run the dump, then set Instance Count back to 1.

    # dump Mongo (name filter is anchored so it matches exactly one container)
    docker exec $(docker ps -qf name=^srv-captain--<app>-mongodb\.) mongodump \
      -u librechat -p <password> --authenticationDatabase admin --archive --gzip \
      > librechat-<date>.archive.gz

    # volumes
    docker run --rm -v <app>-uploads:/data:ro -v $PWD:/backup alpine tar czf /backup/uploads-<date>.tgz -C /data .
    docker run --rm -v <app>-images:/data:ro -v $PWD:/backup alpine tar czf /backup/images-<date>.tgz -C /data .

### 4.1 Restore

    # fresh install of the app first (same app name), then, with Instance Count = 0:
    docker exec -i $(docker ps -qf name=^srv-captain--<app>-mongodb\.) mongorestore \\
      -u librechat -p <password> --authenticationDatabase admin --archive --gzip --drop < librechat-<date>.archive.gz
    # volumes: untar into the fresh volumes
    docker run --rm -v <app>-uploads:/data -v $PWD:/backup alpine sh -c 'cd /data && tar xzf /backup/uploads-<date>.tgz --strip-components=0'

### 4.2 Verify after restore

    # login works, an old conversation opens, an uploaded file loads, a stored
    # user API key still works (spec 5.9). CREDS_KEY/CREDS_IV must match the
    # backed-up values - without them stored keys are unreadable.

## 5. Memory limits (servers that need them)

If your server is memory-constrained, give each app of the stack a memory
limit in CapRover (App Configs - Service Update Override):

    TaskTemplate:
      Resources:
        Limits:
          MemoryBytes: 1610612736

Apply it to `<app>`, `<app>-mongodb` and `<app>-pg-mcp` (1.5 GB each here). Store CREDS_KEY, CREDS_IV, the JWT secrets and the Mongo password (App Configs env view) somewhere safe right after install: without CREDS_* a restored install cannot read stored user API keys.

## 6. MCP change procedure (summary)

| Change | Steps |
|---|---|
| Windmill/Superset URL or token | Edit env on the api app, redeploy. Clearing the URL removes the entry. |
| Postgres on | DATABASE_URI on `-pg-mcp`, redeploy, then PG_MCP_ENABLED=1 on api, redeploy. |
| Postgres off | PG_MCP_ENABLED=0 on api, redeploy, then clear DATABASE_URI on `-pg-mcp`, redeploy. |
| Token rotation | Mint a new token, edit *_MCP_TOKEN, redeploy. |
