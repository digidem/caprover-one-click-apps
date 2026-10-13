#!/usr/bin/env node
// Generator test for the LibreChat one-click app (spec 5.2, 5.2b, 5.12).
// Runs scripts/librechat-boot.sh inside the pinned librechat-api image and
// asserts: byte-equality with the template command, regex parity, case matrix,
// schema (via the boot post-check), expected mcpServers keys, no secret
// leakage, reject-before-write, and no payload execution.
// Needs docker. Run: npm run test_librechat
"use strict";
const fs = require("fs");
const path = require("path");
const cp = require("child_process");
const y = require("yaml");

const ROOT = path.resolve(__dirname, "..");
const BOOT = path.join(ROOT, "scripts/librechat-boot.sh");
const TPL = path.join(ROOT, "public/v4/apps/librechat.yml");
const IMG = process.env.IMG || "docker.io/librechat/librechat-api:v0.8.8";
let fails = 0;
const ok = (m) => console.log("PASS:", m);
const bad = (m) => { console.log("FAIL:", m); fails++; };

function die(msg) {
  console.error("test_librechat: " + msg);
  process.exit(1);
}

// ---- 1. template command byte-equals the canonical script -------------------
{
  const boot = fs.readFileSync(BOOT, "utf8");
  const doc = y.parse(fs.readFileSync(TPL, "utf8"));
  const cmd = doc.services["$$cap_appname"].command;
  if (cmd[0] !== "sh" || cmd[1] !== "-c") die("template command shape wrong");
  if (cmd[2] !== boot) die("template command is not byte-equal to scripts/librechat-boot.sh");
  if (cmd[2].includes("$$cap_")) die("$$cap_* leaked into command text");
  ok("template command byte-equals scripts/librechat-boot.sh");
}

// ---- 2. regex parity (template validRegex vs boot pre-check) ----------------
{
  const boot = fs.readFileSync(BOOT, "utf8");
  const doc = y.parse(fs.readFileSync(TPL, "utf8")).caproverOneClickApp.variables;
  const norm = (r) => r.replace(/\[A-Za-z0-9_\]/g, "\\w");
  const bootRe = {};
  for (const m of boot.matchAll(/^(?:  )?([A-Z_]+): (\/.+\/),?$/gm)) bootRe[m[1]] = m[2];
  for (const v of doc) {
    const id = v.id.replace("$$cap_", "").toUpperCase();
    const map = { LLM_NAME: "LLM_NAME", LLM_DEFAULT_MODEL: "LLM_DEFAULT_MODEL", LLM_MODELS: "LLM_MODELS", LLM_API_KEY: "LLM_API_KEY", WINDMILL_MCP_TOKEN: "WINDMILL_MCP_TOKEN", SUPERSET_MCP_TOKEN: "SUPERSET_MCP_TOKEN", PG_MCP_ENABLED: "PG_MCP_ENABLED" };
    const target = map[id];
    if (!target) continue;
    const a = norm(v.validRegex), b = norm(bootRe[target]);
    if (!b) bad("pre-check has no regex for " + target);
    else if (a !== b) bad("regex mismatch for " + id + ": template=" + a + " boot=" + b);
    else ok("regex parity: " + id);
  }
}


// ---- 3. case matrix in the pinned image --------------------------------------
const BASE_ENV = {
  LLM_NAME: "Tinfoil",
  LLM_DEFAULT_MODEL: "gpt-oss-120b",
  LLM_MODELS: "gpt-oss-120b,kimi-k3,glm-5-3,gemma4-31b,llama3-3-70b",
  PG_MCP_ENABLED: "0",
  LLM_API_KEY: "",
  LLM_BASE_URL: "https://inference.tinfoil.sh/v1",
  PG_MCP_URL: "http://srv-captain--test-pg-mcp:8000/sse",
  CONFIG_PATH: "/app/librechat.yaml",
};

const BOOT_BODY = "/tmp/librechat_boot_body.sh";

function bootBodyPath() {
  const boot = fs.readFileSync(BOOT, "utf8");
  const lines = boot.trimEnd().split("\n");
  if (!/^exec node server\/index\.js$/.test(lines[lines.length - 1])) {
    die("boot script must end with the exec line");
  }
  lines[lines.length - 1] = "echo BOOT_DONE";
  const p = path.join(ROOT, "scripts", ".test_boot_body.sh");
  fs.writeFileSync(p, lines.join("\n") + "\n");
  return p;
}

function runCase(envOverrides) {
  const envFull = Object.assign({}, BASE_ENV, envOverrides || {});
  const pwnDir = path.join(ROOT, "scripts", ".pwned-probe");
  fs.rmSync(pwnDir, { force: true, recursive: true });
  fs.mkdirSync(pwnDir, { recursive: true });
  const args = ["run", "--rm", "--entrypoint", "sh"];
  for (const [k, v] of Object.entries(envFull)) args.push("-e", k + "=" + v);
  args.push("-v", bootBodyPath() + ":/tmp/boot_body.sh:ro");
  args.push("-v", pwnDir + ":/pwnprobe");
  args.push(IMG, "-c", [
    "echo SENTINEL > /app/librechat.yaml",
    "rm -f /tmp/pwned",
    "sh /tmp/boot_body.sh; rc=$?",
    "echo RC=$rc",
    "echo ---CONFIG---",
    "cat /app/librechat.yaml",
    "echo ---END---",
    "test -e /tmp/pwned && cp /tmp/pwned /pwnprobe/pwned || true",
  ].join("\n"));
  const r = cp.spawnSync("docker", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  const out = (r.stdout || "") + (r.stderr || "");
  const m = out.match(/^RC=(\d+)$/m);
  const cm = out.match(/---CONFIG---\n([\s\S]*?)\n---END---/);
  const pwned = fs.existsSync(path.join(pwnDir, "pwned"));
  fs.rmSync(pwnDir, { force: true, recursive: true });
  return { rc: m ? parseInt(m[1], 10) : null, config: cm ? cm[1] : "", out, pwned };
}

const CASES = [
  { name: "no MCP", env: {}, keys: [], expect: "ok" },
  { name: "pg only", env: { PG_MCP_ENABLED: "1" }, keys: ["postgres"], expect: "ok" },
  { name: "windmill only", env: { WINDMILL_MCP_URL: "http://srv-captain--windmill:8000/api/mcp/w/librechat-agent/mcp", WINDMILL_MCP_TOKEN: "SEKR_WILL_1" }, keys: ["windmill"], expect: "ok" },
  { name: "superset only", env: { SUPERSET_MCP_URL: "http://srv-captain--superset-mcp:5008/mcp", SUPERSET_MCP_TOKEN: "SEKR_SUP_1" }, keys: ["superset"], expect: "ok" },
  { name: "superset with empty token", env: { SUPERSET_MCP_URL: "http://srv-captain--superset-mcp:5008/mcp" }, keys: ["superset"], expect: "ok", noBearer: ["superset"] },
  { name: "all MCP", env: { PG_MCP_ENABLED: "1", WINDMILL_MCP_URL: "http://srv-captain--windmill:8000/api/mcp/w/librechat-agent/mcp", WINDMILL_MCP_TOKEN: "SEKR_WILL_2", SUPERSET_MCP_URL: "http://srv-captain--superset-mcp:5008/mcp", SUPERSET_MCP_TOKEN: "SEKR_SUP_2" }, keys: ["postgres", "windmill", "superset"], expect: "all" },
];

// extra ok-case: LLM key set (placeholder must appear, value must not leak)
CASES.push({
  name: "LLM key set", env: { LLM_API_KEY: "tfk_SEKR_LLM_1" }, keys: [], expect: "ok",
  contains: ["apiKey: '${LLM_API_KEY}'"], notContains: ["tfk_SEKR_LLM_1"],
});

// token without URL: entry must be absent
CASES.push({
  name: "windmill token without URL", env: { WINDMILL_MCP_TOKEN: "SEKR_WILL_3" }, keys: [], expect: "ok",
});
CASES.push({
  name: "superset token without URL", env: { SUPERSET_MCP_TOKEN: "SEKR_SUP_3" }, keys: [], expect: "ok",
});

// failing cases: non-zero exit, sentinel untouched, no payload execution
const FAIL_CASES = [
  { name: "apostrophe in LLM_NAME", env: { LLM_NAME: "Trx;'x" } },
  { name: "PG_MCP_ENABLED=2", env: { PG_MCP_ENABLED: "2" } },
  { name: "token query in LLM_BASE_URL", env: { LLM_BASE_URL: "https://h/x?token=abc" } },
  { name: "userinfo in URL", env: { WINDMILL_MCP_URL: "https://u:p@h/x" } },
  { name: "space in WINDMILL token", env: { WINDMILL_MCP_URL: "http://srv-captain--w:8000/mcp", WINDMILL_MCP_TOKEN: "abc def" } },
  { name: "plain http external URL", env: { SUPERSET_MCP_URL: "http://example.com/mcp" } },
  { name: "payload in LLM_NAME", env: { LLM_NAME: "Trx;$(id > /tmp/pwned)'x" }, checkPwned: true },
  { name: "newline in LLM_NAME", env: { LLM_NAME: "bad\nname" }, checkPwned: true },
];

// ---- 4. run cases and assert --------------------------------------------------
const SECRETS_IN_PLAY = ["SEKR_WILL_1", "SEKR_WILL_2", "SEKR_WILL_3", "SEKR_SUP_1", "SEKR_SUP_2", "SEKR_SUP_3", "tfk_SEKR_LLM_1"];

for (const c of CASES) {
  const r = runCase(c.env);
  if (r.rc !== 0) { bad(c.name + ": expected rc 0, got " + r.rc + "\n" + r.out.slice(-400)); continue; }
  const cfg = r.config;
  if (cfg.includes("SENTINEL")) { bad(c.name + ": config still sentinel"); continue; }
  if (r.out.includes("PWNED") || r.pwned) { bad(c.name + ": payload executed"); continue; }
  const doc = y.parse(cfg);
  const mcp = (doc.mcpServers || {});
  const got = Object.keys(mcp).sort().join(",");
  const want = c.keys.slice().sort().join(",");
  if (got !== want) { bad(c.name + ": mcpServers " + got + " != " + want); continue; }
  if (c.noBearer && c.noBearer.includes("superset") && JSON.stringify(mcp.superset || {}).includes("Bearer")) {
    bad(c.name + ": superset must have no Authorization header");
    continue;
  }
  for (const s of SECRETS_IN_PLAY) if (cfg.includes(s)) { bad(c.name + ": leaked " + s); }
  if (c.contains) for (const t of c.contains) if (!cfg.includes(t)) bad(c.name + ": missing " + t);
  if (c.notContains) for (const t of c.notContains) if (cfg.includes(t)) bad(c.name + ": leaked " + t);
  if (!cfg.includes("name: 'Tinfoil'")) bad(c.name + ": endpoint name not concrete");
  for (const m of BASE_ENV.LLM_MODELS.split(",")) {
    if (!cfg.includes("- '" + m + "'")) bad(c.name + ": model missing from list: " + m);
  }
  ok(c.name);
}

for (const c of FAIL_CASES) {
  const r = runCase(c.env);
  if (r.rc === 0) { bad(c.name + ": expected non-zero rc"); continue; }
  if (!r.config.includes("SENTINEL")) { bad(c.name + ": sentinel was overwritten"); continue; }
  if (c.checkPwned && (r.out.includes("PWNED") || r.pwned)) { bad(c.name + ": payload executed"); continue; }
  ok(c.name + " (rejected before write)");
}

fs.rmSync(path.join(ROOT, "scripts", ".test_boot_body.sh"), { force: true });
if (fails > 0) { console.log("FAILED: " + fails + " check(s)"); process.exit(1); }
console.log("ALL CHECKS PASSED");
