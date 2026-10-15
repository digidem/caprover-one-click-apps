// GC skills and prompt seeding tests for the LibreChat one-click app (task_plan.md
// "Test matrix"). Called from scripts/test_librechat_config.js after the generator
// checks. Needs docker. Each docker call uses the pinned librechat-api image.
// Live Mongo cases start a throwaway mongo:8.0.20 container and remove it afterwards.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const BOOT = path.join(ROOT, "scripts/librechat-boot.sh");
const SEED = path.join(ROOT, "scripts/gc/seed/gc_seed.cjs");
const PROMPTS = path.join(ROOT, "skills/gc/prompts");
const IMG = process.env.IMG || "docker.io/librechat/librechat-api:v0.8.8";
const MONGO_IMG = process.env.MONGO_IMG || "mongo:8.0.20";
const SKIP_LIVE = process.env.GC_TEST_SKIP_LIVE === "1";

let fails = 0;
const ok = (m) => console.log("PASS:", m);
const bad = (m) => { console.log("FAIL:", m); fails++; };

// Note on ownership: the containers run as the image's own user (root here)
// because the pinned image writes to /app/api/logs and /app/skills. Anything
// they leave in a bind-mounted tmpdir is therefore owned by that user, and the
// host cleanup can hit EACCES on a non-root host. That is a cleanup concern, not
// a behaviour one: `rmDir` below tolerates it and reports rather than aborting.
function docker(args, input) {
  return cp.spawnSync("docker", args, { encoding: "utf8", input: input, maxBuffer: 64 * 1024 * 1024 });
}

function tmpDir(tag) {
  return fs.mkdtempSync(path.join(os.tmpdir(), "gc-test-" + tag + "-"));
}

// A tmpdir that a container wrote into is removed by the container's exit; the
// host copy may still hold files owned by the container's uid if --user was not
// applied. Never let cleanup failure mask a passed check: report it, keep going.
function rmDir(dir) {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
    return true;
  } catch (err) {
    // a leftover tmpdir is noise, not a failure of the behaviour under test
    console.log("note: could not remove " + dir + " (" + err.code + ")");
    return false;
  }
}

// Starter count per family, from the H2 sections the seeder parses.
function starterCount(family) {
  const text = fs.readFileSync(path.join(PROMPTS, family + ".md"), "utf8");
  return (text.match(/^## .+$/gm) || []).length;
}

// ---- A. static checks ---------------------------------------------------------
function staticChecks() {
  const boot = fs.readFileSync(BOOT, "utf8");
  if (boot.includes("$$")) bad("boot script contains a dollar-dollar sequence");
  else ok("boot script has no dollar-dollar sequence");

  const gen = cp.spawnSync("sh", [path.join(ROOT, "scripts/gc_skills_bundle.sh")], { encoding: "utf8" });
  if (gen.status !== 0) { bad("gc_skills_bundle.sh failed: " + gen.stderr); return; }
  const begin = boot.indexOf("# BEGIN GC PAYLOAD");
  const end = boot.indexOf("# END GC PAYLOAD");
  const block = boot.slice(begin, end + "# END GC PAYLOAD\n".length);
  if (block === gen.stdout) ok("GC payload in boot script is up to date with its sources");
  else bad("GC payload is stale: run node scripts/sync_librechat_boot.js");

  for (const f of ["gc-core", "gc-mapeo", "gc-alerts", "gc-kobo", "gc-rastro"]) {
    const skill = fs.readFileSync(path.join(ROOT, "skills/gc", f, "SKILL.md"), "utf8");
    const name = /^name: (.+)$/m.exec(skill);
    if (!name || name[1].trim() !== f) bad("frontmatter name mismatch in " + f);
    if (skill.includes("$$")) bad(f + " contains a dollar-dollar sequence");
  }
  ok("skill frontmatter names match folders; no dollar-dollar sequences in skills");
}

// ---- B. validators in the pinned image ---------------------------------------
function validatorChecks() {
  const good = tmpDir("valid-good");
  const bad1 = tmpDir("valid-bad");
  for (const f of ["gc-core", "gc-mapeo", "gc-alerts", "gc-kobo", "gc-rastro"]) {
    fs.mkdirSync(path.join(good, f));
    fs.copyFileSync(path.join(ROOT, "skills/gc", f, "SKILL.md"), path.join(good, f, "SKILL.md"));
  }
  fs.mkdirSync(path.join(bad1, "gc-core"));
  fs.writeFileSync(path.join(bad1, "gc-core", "SKILL.md"), "---\nname: wrong-name\ndescription: x\n---\nbody\n");
  const run = (dir) => docker([
    "run", "--rm", "--entrypoint", "sh",
    "-e", "NODE_PATH=/app/node_modules",
    "-v", SEED + ":/gc/gc_seed.cjs:ro",
    "-v", dir + ":/stage:ro",
    IMG, "-c", "node /gc/gc_seed.cjs validate-skills /stage",
  ]);
  const g = run(good);
  if (g.status === 0) ok("shipped skills pass LibreChat skill validation in the pinned image");
  else bad("shipped skills failed validation: " + (g.stdout + g.stderr).slice(-600));
  const b = run(bad1);
  if (b.status !== 0 && /GC_PROVISION_DEGRADED/.test(b.stderr)) ok("name mismatch is rejected with GC_PROVISION_DEGRADED");
  else bad("name mismatch was not rejected (status " + b.status + ")");
  rmDir(good);
  rmDir(bad1);
}

// ---- C. boot-script flag matrix (no Mongo, fast) ------------------------------
// Runs the boot script body with the GC section, server replaced by echo.
function bootBody() {
  const lines = fs.readFileSync(BOOT, "utf8").trimEnd().split("\n");
  lines[lines.length - 1] = "echo BOOT_DONE";
  return lines.join("\n") + "\n";
}

const BASE = {
  LLM_NAME: "Tinfoil",
  LLM_DEFAULT_MODEL: "gpt-oss-120b",
  LLM_MODELS: "gpt-oss-120b",
  PG_MCP_ENABLED: "0",
  LLM_BASE_URL: "https://inference.tinfoil.sh/v1",
};

function runBoot(env) {
  const dir = tmpDir("boot");
  fs.writeFileSync(path.join(dir, "body.sh"), bootBody());
  const args = ["run", "--rm", "--entrypoint", "sh", "-v", dir + ":/probe"];
  const all = Object.assign({}, BASE, env || {});
  for (const [k, v] of Object.entries(all)) args.push("-e", k + "=" + v);
  args.push(IMG, "-c", [
    "mkdir -p /app/skills",
    "sh /probe/body.sh; echo RC=$?",
    "echo ---SKILLS---; ls /app/skills 2>/dev/null | sort; echo ---END---",
  ].join("\n"));
  const r = docker(args);
  rmDir(dir);
  const out = (r.stdout || "") + (r.stderr || "");
  const rc = /^RC=(\d+)$/m.exec(out);
  const skills = /---SKILLS---\n([\s\S]*?)---END---/.exec(out);
  return {
    rc: rc ? parseInt(rc[1], 10) : null,
    out: out,
    skills: skills ? skills[1].split("\n").map((s) => s.trim()).filter(Boolean) : [],
  };
}

function bootChecks() {
  const off = runBoot({});
  if (off.rc !== 0) bad("flags absent: boot rc " + off.rc);
  else if (/GC_PROVISION_DEGRADED/.test(off.out)) bad("flags absent: unexpected DEGRADED output");
  else if (off.skills.some((s) => s.startsWith("gc-"))) bad("flags absent: skills were published");
  else ok("flags absent (opt-in by absence): nothing published, chat boots");

  const bogus = runBoot({ GC_SKILLS_ENABLED: "yes" });
  if (bogus.rc !== 0) bad("invalid master flag: boot rc " + bogus.rc);
  else if (!/GC_PROVISION_DEGRADED: flags:/.test(bogus.out)) bad("invalid master flag: no DEGRADED marker");
  else if (bogus.skills.some((s) => s.startsWith("gc-"))) bad("invalid master flag: skills were published");
  else ok("invalid master flag: provisioning disabled with GC_PROVISION_DEGRADED, chat boots");

  const hint = runBoot({ GC_SKILLS_ENABLED: "1", GC_SKILLS_DB_WAREHOUSE: "War;ehouse" });
  if (!/GC_PROVISION_DEGRADED: hints:/.test(hint.out)) bad("hostile hint: no DEGRADED marker");
  else if (hint.skills.some((s) => s.startsWith("gc-"))) bad("hostile hint: skills were published");
  else ok("hostile hint rejected before any skill is written");

  const on = runBoot({ GC_SKILLS_ENABLED: "1", GC_SKILLS_DB_WAREHOUSE: "Warehouse", GC_SKILLS_DB_RASTRO: "Rastro" });
  const want = ["gc-alerts", "gc-core", "gc-install", "gc-mapeo"];
  if (on.rc !== 0) bad("master on, no Mongo: boot rc " + on.rc);
  else if (JSON.stringify(on.skills) !== JSON.stringify(want)) bad("master on: published " + on.skills.join(",") + " expected " + want.join(","));
  else if (!/GC_PROVISION_DEGRADED: seeder: MONGO_URI is not set/.test(on.out)) bad("master on, no Mongo: seeder did not degrade");
  else ok("master on with defaults: core, install, mapeo, alerts published; seeder degrades without Mongo; chat boots");

  const kobo = runBoot({ GC_SKILLS_ENABLED: "1", GC_SKILL_KOBO: "1", GC_SKILL_MAPEO: "0", GC_SKILL_ALERTS: "0" });
  if (JSON.stringify(kobo.skills) !== JSON.stringify(["gc-core", "gc-install", "gc-kobo"])) bad("kobo opt-in matrix: " + kobo.skills.join(","));
  else ok("domain flags: explicit kobo on, mapeo and alerts off");
}

// ---- D. live seeding against a throwaway Mongo -------------------------------
function liveChecks() {
  const name = "gc-test-mongo-" + process.pid;
  const net = "gc-test-net-" + process.pid;
  const skills = tmpDir("skills");
  const cleanup = () => {
    docker(["rm", "-f", name]);
    docker(["network", "rm", net]);
    rmDir(skills);
  };
  if (docker(["network", "create", net]).status !== 0) { bad("cannot create docker network"); return; }
  if (docker(["run", "-d", "--name", name, "--network", net, MONGO_IMG]).status !== 0) { bad("cannot start " + MONGO_IMG); cleanup(); return; }
  const seedRun = (env) => {
    const args = ["run", "--rm", "--network", net, "--entrypoint", "sh",
      "-e", "NODE_PATH=/app/node_modules",
      "-e", "MONGO_URI=mongodb://" + name + ":27017/LibreChat",
      "-v", SEED + ":/gc/gc_seed.cjs:ro",
      "-v", PROMPTS + ":/app/gc-seed/prompts:ro",
      "-v", skills + ":/app/skills",
      "-w", "/app/api"];
    for (const [k, v] of Object.entries(env)) args.push("-e", k + "=" + v);
    args.push(IMG, "-c", "node /gc/gc_seed.cjs seed");
    return docker(args);
  };
  const expectedNew = starterCount("gc-core") + starterCount("gc-mapeo") + starterCount("gc-alerts");
  const on = { GC_SKILLS_ENABLED: "1", GC_SKILL_MAPEO: "1", GC_SKILL_ALERTS: "1", GC_SKILL_KOBO: "0", GC_SKILL_RASTRO: "0" };
  try {
    // Mongo may need a few seconds to accept connections.
    const first = seedRun(on);
    const firstOut = first.stdout + first.stderr;
    const m1 = /created=(\d+) updated=(\d+) removed=(\d+) conflicts=(\d+)/.exec(firstOut);
    if (!m1 || Number(m1[1]) !== expectedNew) bad("first seed created " + (m1 ? m1[1] : "?") + ", expected " + expectedNew + "\n" + firstOut.slice(-400));
    else ok("cold seed creates " + expectedNew + " starter prompt groups");

    const again = seedRun(on);
    const m2 = /created=(\d+) updated=(\d+) removed=(\d+) conflicts=(\d+)/.exec(again.stdout + again.stderr);
    if (!m2 || m2[1] !== "0" || m2[2] !== "0") bad("repeat seed was not a no-op: " + (m2 ? m2[0] : "no summary"));
    else ok("repeat seed is a no-op");

    const db = (js) => docker(["run", "--rm", "--network", net, "--entrypoint", "sh", "-e", "NODE_PATH=/app/node_modules",
      "-e", "MONGO_URI=mongodb://" + name + ":27017/LibreChat", "-v", path.join(ROOT, "scripts/gc/seed") + ":/q:ro", IMG,
      "-c", "node -e " + JSON.stringify(js)]);
    const probe = db('const m=require("mongoose");m.connect(process.env.MONGO_URI).then(async()=>{const d=m.connection.db;' +
      'const g=await d.collection("promptgroups").countDocuments({category:/^gc-/});' +
      'const a=await d.collection("aclentries").find({principalType:"public",resourceType:"promptGroup"}).toArray();' +
      'const u=await d.collection("users").countDocuments({});' +
      'const dbl=await d.collection("promptgroups").countDocuments({category:/^gc-gc-/});' +
      'console.log("GROUPS="+g+" PUBLIC_ACL="+a.length+" USERS="+u+" ROLE="+(a[0]?String(a[0].permBits):"none")+" DOUBLE="+dbl);await m.disconnect();});');
    const pout = probe.stdout + probe.stderr;
    if (new RegExp("GROUPS=" + expectedNew + " PUBLIC_ACL=" + expectedNew + " USERS=0 ROLE=1 DOUBLE=0").test(pout)) ok("seeded groups are public (permBits 1); no User row is created");
    else bad("live state wrong: " + pout.slice(-300));

    const off = seedRun({ GC_SKILLS_ENABLED: "0" });
    const m3 = /created=(\d+) updated=(\d+) removed=(\d+) conflicts=(\d+)/.exec(off.stdout + off.stderr);
    if (!m3 || Number(m3[3]) !== expectedNew) bad("disable did not remove managed content: " + (m3 ? m3[0] : (off.stdout + off.stderr).slice(-200)));
    else ok("disable removes unchanged managed prompt groups");
    const probe2 = db('const m=require("mongoose");m.connect(process.env.MONGO_URI).then(async()=>{const d=m.connection.db;' +
      'console.log("GROUPS="+await d.collection("promptgroups").countDocuments({category:/^gc-/}));await m.disconnect();});');
    if (/GROUPS=0/.test(probe2.stdout + probe2.stderr)) ok("no managed prompt groups remain after disable");
    else bad("managed prompt groups remain after disable");
  } finally {
    cleanup();
  }
}

function runAll() {
  staticChecks();
  validatorChecks();
  bootChecks();
  if (SKIP_LIVE) console.log("SKIP: live Mongo seeding (GC_TEST_SKIP_LIVE=1)");
  else liveChecks();
  return fails;
}

module.exports = { runAll };

if (require.main === module) {
  const failed = runAll();
  console.log(failed ? "FAILED: " + failed + " check(s)" : "GC CHECKS PASSED");
  process.exit(failed ? 1 : 0);
}
