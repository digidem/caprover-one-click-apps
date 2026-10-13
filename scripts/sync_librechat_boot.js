#!/usr/bin/env node
// Keeps public/v4/apps/librechat.yml's api command byte-equal to
// scripts/librechat-boot.sh. Run after editing the boot script:
//   node scripts/sync_librechat_boot.js && npx prettier --check public/v4/apps/librechat.yml
"use strict";
const fs = require("fs");
const path = require("path");
const y = require("yaml");
const ROOT = path.resolve(__dirname, "..");
const boot = fs.readFileSync(path.join(ROOT, "scripts/librechat-boot.sh"), "utf8");
let t = fs.readFileSync(path.join(ROOT, "public/v4/apps/librechat.yml"), "utf8");
const lines = t.split("\n");
const start = lines.findIndex((l) => l === "        command:");
const vol = lines.findIndex((l) => l === "        volumes:");
if (start < 0 || vol < 0 || vol <= start) die("command/volumes anchors not found");
function die(m) { console.error("sync_librechat_boot: " + m); process.exit(1); }
const block = [
  "        command:",
  "            - 'sh'",
  "            - '-c'",
  "            - " + JSON.stringify(boot),
].join("\n");
lines.splice(start, vol - start, block);
t = lines.join("\n");
fs.writeFileSync(path.join(ROOT, "public/v4/apps/librechat.yml"), t);
const parsed = y.parse(t).services["$$cap_appname"].command;
if (parsed[2] !== boot) die("post-splice byte-equality failed");
console.log("synced, byte-equal: true");
