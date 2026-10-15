'use strict';
// GC boot seeder for LibreChat v0.8.8 (spec: task_plan.md "Seeder must-dos").
// Canonical source. Embedded byte-equal into the one-click boot script by
// scripts/gc_skills_bundle.sh through a quoted heredoc, so this file must not
// contain the dollar sign followed by a dollar sign, backticks, or template
// literals. Runs before the server starts and always exits 0: every failure is
// logged as GC_PROVISION_DEGRADED and chat still starts.
//
// Modes (argv[2]):
//   validate-skills <dir>  check each child SKILL.md with LibreChat's validators
//   seed                   reconcile prompt groups and public ACLs with the env flags

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const MARK = 'GC_PROVISION_DEGRADED';
const DEADLINE_MS = 150000;
const CONNECT_BUDGET_MS = 90000;
const STATE_DIR = '/app/skills/.gc-state';
const STATE_FILE = path.join(STATE_DIR, 'seed.json');
const PROMPTS_DIR = '/app/gc-seed/prompts';
const VIEWER_ROLE_ID = 'promptGroup_viewer';
const OWNER_ROLE_ID = 'promptGroup_owner';
const OWNER_ROLE_NAME = 'com_ui_role_owner';
const OWNER_ROLE_DESC = 'com_ui_role_owner_desc';
const AUTHOR_NAME = 'Guardian Connector';
const MANAGED_PREFIX = 'gc-prompt:';

function degraded(area, reason) {
  console.error(MARK + ': ' + area + ': ' + reason + '. Remediation: check GC_SKILLS_* settings and the api logs for "librechat-boot", then redeploy.');
}

function hexId(seed) {
  return crypto.createHash('sha1').update(seed).digest('hex').slice(0, 24);
}

// Synthetic author. No User row is created, so LibreChat's first-user admin
// bootstrap (countUsers() === 0) stays intact. See docs/librechat-integrations.md.
const AUTHOR_HEX = hexId('gc-service:author');
const ROLE_NAME = 'com_ui_role_viewer';
const ROLE_DESC = 'com_ui_role_viewer_desc';

process.on('unhandledRejection', function (err) {
  degraded('seeder', 'unhandled rejection: ' + (err && err.message ? err.message : String(err)));
  process.exit(0);
});
process.on('uncaughtException', function (err) {
  degraded('seeder', 'uncaught exception: ' + (err && err.message ? err.message : String(err)));
  process.exit(0);
});

// Wall-clock deadline armed before any connection attempt.
setTimeout(function () {
  degraded('seeder', 'wall-clock deadline of ' + DEADLINE_MS + ' ms reached');
  process.exit(0);
}, DEADLINE_MS).unref();

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

// ---------- starter prompt files -------------------------------------------

// Format: H1 title line, then "## <title>" sections. Each section body is the prompt.
function parseStarters(family, text) {
  const out = [];
  const lines = text.split(/\r?\n/);
  let title = null;
  let body = [];
  function flush() {
    if (title !== null) {
      const prompt = body.join('\n').trim();
      if (prompt.length > 0) out.push({ family: family, title: title, prompt: prompt });
    }
  }
  for (const line of lines) {
    const m = /^## (.+)$/.exec(line);
    if (m) {
      flush();
      title = m[1].trim();
      body = [];
    } else if (title !== null) {
      body.push(line);
    }
  }
  flush();
  return out;
}

function slugOf(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48);
}

function desiredItems(families) {
  const items = [];
  for (const family of families) {
    const file = path.join(PROMPTS_DIR, family + '.md');
    if (!fs.existsSync(file)) {
      degraded('prompts', 'missing prompt file for ' + family);
      continue;
    }
    for (const starter of parseStarters(family, fs.readFileSync(file, 'utf8'))) {
      if (starter.prompt.length > 2000) {
        degraded('prompts', 'starter too long: ' + family + '/' + starter.title);
        continue;
      }
      const key = family + '/' + slugOf(starter.title);
      const fields = {
        name: starter.title,
        category: family,
        oneliner: 'Guardian Connector starter (' + family + ')',
        prompt: starter.prompt,
      };
      items.push({
        key: key,
        groupId: hexId(MANAGED_PREFIX + key + ':group'),
        promptId: hexId(MANAGED_PREFIX + key + ':prompt'),
        aclId: hexId(MANAGED_PREFIX + key + ':acl'),
        ownerAclId: hexId(MANAGED_PREFIX + key + ':owner-acl'),
        fields: fields,
        hash: sha256(JSON.stringify(fields)),
      });
    }
  }
  return items;
}

function readState() {
  try {
    const parsed = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    if (parsed && parsed.version === 1 && parsed.items) return parsed;
    degraded('state', 'unrecognized seed state file; ignoring it');
    return null;
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    degraded('state', 'cannot read seed state: ' + err.message);
    return null;
  }
}

function writeState(state) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const tmp = STATE_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, STATE_FILE);
}

// ---------- validate-skills ------------------------------------------------

function validateSkills(dir) {
  const dsc = require('@librechat/data-schemas');
  let failed = false;
  const names = fs.readdirSync(dir, { withFileTypes: true }).filter(function (e) { return e.isDirectory(); }).map(function (e) { return e.name; });
  for (const name of names) {
    const file = path.join(dir, name, 'SKILL.md');
    if (!fs.existsSync(file)) continue;
    const content = fs.readFileSync(file, 'utf8');
    const fm = /^---\n([\s\S]*?)\n---/.exec(content);
    if (!fm) { degraded('skills', name + ': missing frontmatter'); failed = true; continue; }
    const nameLine = /^name: *(.+)$/m.exec(fm[1]);
    const descLine = /^description: *(.+)$/m.exec(fm[1]);
    const skillName = nameLine ? nameLine[1].trim() : '';
    const description = descLine ? descLine[1].trim() : '';
    const issues = [].concat(
      dsc.validateSkillName(skillName),
      dsc.validateSkillDescription(description),
      dsc.validateSkillBody(content)
    );
    const parts = dsc.partitionIssues(issues);
    if (skillName !== name) { degraded('skills', name + ': frontmatter name does not match folder'); failed = true; }
    if (parts.errors.length > 0) {
      degraded('skills', name + ': ' + parts.errors.map(function (i) { return i.field + ' ' + i.message; }).join('; '));
      failed = true;
    }
  }
  return failed ? 1 : 0;
}

// ---------- seed -----------------------------------------------------------

function families(env) {
  const list = [];
  if (env.GC_SKILLS_ENABLED !== '1') return list;
  list.push('gc-core');
  if (env.GC_SKILL_MAPEO === '1') list.push('gc-mapeo');
  if (env.GC_SKILL_ALERTS === '1') list.push('gc-alerts');
  if (env.GC_SKILL_KOBO === '1') list.push('gc-kobo');
  if (env.GC_SKILL_RASTRO === '1') list.push('gc-rastro');
  return list;
}

async function connect(uri) {
  const mongoose = require('mongoose');
  const started = Date.now();
  let delay = 1000;
  for (;;) {
    try {
      await mongoose.connect(uri, { serverSelectionTimeoutMS: 5000, maxPoolSize: 2 });
      return mongoose;
    } catch (err) {
      if (Date.now() - started + delay > CONNECT_BUDGET_MS) throw new Error('mongo unreachable within budget: ' + err.message);
      await new Promise(function (r) { setTimeout(r, delay); });
      delay = Math.min(delay * 2, 10000);
    }
  }
}

// Ensures the viewer and owner roles (same shape as LibreChat seedDefaultRoles).
async function ensureRole(models, accessRoleId, name, description, permBits) {
  await models.AccessRole.updateOne(
    { accessRoleId: accessRoleId },
    { $setOnInsert: { accessRoleId: accessRoleId, name: name, description: description, resourceType: 'promptGroup', permBits: permBits } },
    { upsert: true }
  );
  const role = await models.AccessRole.findOne({ accessRoleId: accessRoleId }).lean();
  return role ? role._id : null;
}

async function ensureRoles(models) {
  const viewer = await ensureRole(models, VIEWER_ROLE_ID, ROLE_NAME, ROLE_DESC, 1);
  const owner = await ensureRole(models, OWNER_ROLE_ID, OWNER_ROLE_NAME, OWNER_ROLE_DESC, 15);
  return { viewer: viewer, owner: owner };
}

async function dbHashOf(models, groupId) {
  const group = await models.PromptGroup.findById(groupId).lean();
  if (!group) return { group: null, hash: null };
  const prompt = await models.Prompt.findById(group.productionId).lean();
  const fields = {
    name: group.name,
    category: group.category,
    oneliner: group.oneliner,
    prompt: prompt ? prompt.prompt : null,
  };
  return { group: group, hash: sha256(JSON.stringify(fields)) };
}

async function upsertContent(models, item) {
  await models.Prompt.updateOne(
    { _id: item.promptId },
    { $set: { prompt: item.fields.prompt, type: 'text', groupId: item.groupId, author: AUTHOR_HEX } },
    { upsert: true }
  );
  await models.PromptGroup.updateOne(
    { _id: item.groupId },
    {
      $set: {
        name: item.fields.name,
        category: item.fields.category,
        oneliner: item.fields.oneliner,
        productionId: item.promptId,
      },
      $setOnInsert: { author: AUTHOR_HEX, authorName: AUTHOR_NAME, numberOfGenerations: 0 },
    },
    { upsert: true }
  );
}

async function ensurePublicAcl(models, item, roleObjId, report) {
  const existing = await models.AclEntry.findOne({ resourceType: 'promptGroup', resourceId: item.groupId, principalType: 'public' }).lean();
  if (existing) {
    if (roleObjId && String(existing.roleId) !== String(roleObjId)) {
      report.conflicts.push(item.key + ': public ACL role changed by an operator; kept');
    }
    return;
  }
  await models.AclEntry.updateOne(
    { _id: item.aclId },
    {
      $setOnInsert: {
        resourceType: 'promptGroup',
        resourceId: item.groupId,
        principalType: 'public',
        roleId: roleObjId,
        permBits: 1,
        grantedBy: AUTHOR_HEX,
        grantedAt: new Date(),
      },
    },
    { upsert: true }
  );
}

// Revokes every ACL on the group: the public viewer row and the synthetic owner row.
async function revokeItem(models, groupId) {
  await models.AclEntry.deleteMany({ resourceType: 'promptGroup', resourceId: groupId });
}

// Owner row for the synthetic author, so owner-scoped checks resolve.
async function ensureOwnerAcl(models, item, ownerRoleObjId) {
  if (!ownerRoleObjId) return;
  await models.AclEntry.updateOne(
    { _id: item.ownerAclId },
    {
      $setOnInsert: {
        resourceType: 'promptGroup',
        resourceId: item.groupId,
        principalType: 'user',
        principalId: AUTHOR_HEX,
        principalModel: 'User',
        roleId: ownerRoleObjId,
        permBits: 15,
        grantedBy: AUTHOR_HEX,
        grantedAt: new Date(),
      },
    },
    { upsert: true }
  );
}

// Removes only the managed prompt. A group that holds other versions is kept
// (operator drafts stay) and only loses its public ACL.
async function removeItem(models, item, report) {
  await revokeItem(models, item.groupId);
  const others = await models.Prompt.countDocuments({ groupId: item.groupId, _id: { $ne: item.promptId } });
  if (others > 0) {
    report.conflicts.push(item.groupId + ': holds operator versions; only the managed version was left in place, public access revoked');
    return false;
  }
  await models.Prompt.deleteOne({ _id: item.promptId });
  await models.PromptGroup.deleteOne({ _id: item.groupId });
  return true;
}

async function seed(env) {
  const enabled = env.GC_SKILLS_ENABLED === '1';
  const state = readState();
  if (!enabled && !state) {
    console.log('gc-seed: GC_SKILLS_ENABLED is off and nothing is managed; nothing to do');
    return 0;
  }
  const uri = env.MONGO_URI;
  if (!uri) { degraded('seeder', 'MONGO_URI is not set'); return 0; }

  const wanted = desiredItems(families(env));
  const managed = state ? state.items : {};
  const report = { conflicts: [], created: 0, updated: 0, removed: 0 };

  const mongoose = await connect(uri);
  try {
    const models = require('@librechat/data-schemas').createModels(mongoose);
    const roles = await ensureRoles(models);
    const roleObjId = roles.viewer;
    const next = {};
    const wantedKeys = {};
    for (const item of wanted) wantedKeys[item.key] = true;

    // Disable path: managed items no longer wanted.
    for (const key of Object.keys(managed)) {
      if (wantedKeys[key]) continue;
      const old = managed[key];
      const current = await dbHashOf(models, old.groupId);
      if (current.group === null) continue;
      if (current.hash === old.hash) {
        if (await removeItem(models, old, report)) report.removed++;
      } else {
        await revokeItem(models, old.groupId);
        report.conflicts.push(key + ': edited by an operator; kept private, public access revoked');
      }
    }

    // Reconcile wanted items, then publish ACLs last.
    for (const item of wanted) {
      const current = await dbHashOf(models, item.groupId);
      const previous = managed[item.key];
      if (current.group === null) {
        await upsertContent(models, item);
        next[item.key] = { groupId: item.groupId, promptId: item.promptId, hash: item.hash };
        report.created++;
      } else if (current.hash === item.hash) {
        next[item.key] = { groupId: item.groupId, promptId: item.promptId, hash: item.hash };
      } else if (previous && current.hash === previous.hash) {
        await upsertContent(models, item);
        next[item.key] = { groupId: item.groupId, promptId: item.promptId, hash: item.hash };
        report.updated++;
      } else if (previous) {
        report.conflicts.push(item.key + ': edited by an operator; desired content not applied');
        next[item.key] = { groupId: item.groupId, promptId: item.promptId, hash: previous.hash };
      } else {
        // Existing content this seeder never wrote: leave it alone and do not adopt it.
        report.conflicts.push(item.key + ': exists but was not created by GC seeding; left unmanaged');
      }
    }

    // Ledger first: ACLs are published only after the managed state is durable,
    // so a later disable can always find and revoke what was published.
    writeState({ version: 1, items: enabled ? next : {} });

    if (roleObjId) {
      for (const item of wanted) {
        if (next[item.key]) {
          await ensurePublicAcl(models, item, roleObjId, report);
          await ensureOwnerAcl(models, item, roles.owner);
        }
      }
    } else {
      degraded('acl', 'viewer role missing; prompts are not public until the next boot');
    }
    console.log('gc-seed: created=' + report.created + ' updated=' + report.updated + ' removed=' + report.removed + ' conflicts=' + report.conflicts.length);
    for (const c of report.conflicts) console.error(MARK + ': prompts: ' + c + '. Remediation: export your edit, then delete the managed prompt in the UI or set GC_SKILLS_ENABLED=0.');
  } finally {
    await mongoose.disconnect().catch(function () {});
  }
  return 0;
}

async function main() {
  const mode = process.argv[2];
  if (mode === 'validate-skills') {
    return validateSkills(process.argv[3]);
  }
  if (mode === 'seed') {
    return seed(process.env);
  }
  degraded('seeder', 'unknown mode ' + String(mode));
  return 0;
}

main().then(function (code) {
  process.exit(code);
}, function (err) {
  degraded('seeder', err && err.message ? err.message : String(err));
  process.exit(process.argv[2] === 'validate-skills' ? 1 : 0);
});
