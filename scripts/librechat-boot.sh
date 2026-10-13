#!/bin/sh
# LibreChat one-click startup script (canonical source).
# Spec: specs/librechat-mcp.md 3.3. Template public/v4/apps/librechat.yml embeds
# this file byte-equal as element 3 of the api service `command` array; the
# repo test (scripts/test_librechat_config.sh) asserts that equality.
# CapRover template placeholders live only in the template's own fields (image
# tags, service names, env values), never inside this text. All user values
# arrive as env vars and are validated before any write.

set -eu

# librechat-data-provider and js-yaml resolve from these paths in the pinned
# image (specs/spike-images.md). Exported so the checks also work when the
# script runs from another working directory.
NODE_PATH="/app/node_modules:/app/api/node_modules${NODE_PATH:+:$NODE_PATH}"
export NODE_PATH

CONFIG_FILE="${CONFIG_PATH:-/app/librechat.yaml}"
export CONFIG_FILE
TMP_FILE="$CONFIG_FILE.tmp"

# ---------- pre-check: validate resolved env values before any file write ----
# Regexes mirror the 3.4 validRegex strings; scripts/test_librechat_config.sh
# asserts the two stay identical (spec 5.2b).
node -e '
var env = process.env;
var fail = function (name) {
  console.error("librechat-boot: invalid or missing variable: " + name);
  process.exit(1);
};
var re = {
  LLM_NAME: /^[\w .-]{1,32}$/,
  LLM_DEFAULT_MODEL: /^[\w.:\/-]{1,128}$/,
  LLM_MODELS: /^[\w.:\/-]{1,128}([,][\w.:\/-]{1,128}){0,31}$/,
  PG_MCP_ENABLED: /^[01]$/,
  LLM_API_KEY: /^[A-Za-z0-9_.~:-]{0,512}$/,
  WINDMILL_MCP_TOKEN: /^[A-Za-z0-9_.~-]{0,256}$/,
  SUPERSET_MCP_TOKEN: /^[A-Za-z0-9_.~=-]{0,4096}$/
};
var optional = { LLM_API_KEY: 1, WINDMILL_MCP_TOKEN: 1, SUPERSET_MCP_TOKEN: 1 };
Object.keys(re).forEach(function (name) {
  var value = env[name];
  if (optional[name] && (value === undefined || value === null)) value = "";
  if (value === undefined || value === null || !re[name].test(value)) {
    fail(name);
  }
});
var banned = /[\x27\x22\\\s]/;
var urlOk = function (raw) {
  if (banned.test(raw)) return false;
  var u;
  try { u = new URL(raw); } catch (e) { return false; }
  if (u.username || u.password) return false;
  var keys = [];
  u.searchParams.forEach(function (v, k) { keys.push(k); });
  for (var i = 0; i < keys.length; i++) {
    if (/^(token|api_key|apikey|access_token)$/i.test(keys[i])) return false;
  }
  if (u.protocol === "https:") return true;
  return u.protocol === "http:" && /^srv-captain--[a-z0-9-]+$/.test(u.hostname);
};
if (!env.LLM_BASE_URL || !urlOk(env.LLM_BASE_URL)) fail("LLM_BASE_URL");
if (env.WINDMILL_MCP_URL && !urlOk(env.WINDMILL_MCP_URL)) fail("WINDMILL_MCP_URL");
if (env.SUPERSET_MCP_URL && !urlOk(env.SUPERSET_MCP_URL)) fail("SUPERSET_MCP_URL");
'

# ---------- generation --------------------------------------------------------
# Concrete values (endpoint name, default model) are written as single-quoted
# YAML scalars from validated env; everything secret stays a literal ${VAR}
# placeholder that LibreChat resolves from process.env at runtime (spec 3.3).
API_KEY_LINE="      apiKey: 'user_provided'"
if [ -n "${LLM_API_KEY:-}" ]; then
  API_KEY_LINE="      apiKey: '\${LLM_API_KEY}'"
fi

MCP_PART=""
if [ "${PG_MCP_ENABLED}" = "1" ]; then
  MCP_PART="${MCP_PART}  postgres:
    type: sse
    url: '\${PG_MCP_URL}'
    initTimeout: 30000
"
fi
if [ -n "${WINDMILL_MCP_URL:-}" ]; then
  MCP_PART="${MCP_PART}  windmill:
    type: streamable-http
    url: '\${WINDMILL_MCP_URL}'
    initTimeout: 30000
"
  if [ -n "${WINDMILL_MCP_TOKEN:-}" ]; then
    MCP_PART="${MCP_PART}    headers:
      Authorization: 'Bearer \${WINDMILL_MCP_TOKEN}'
"
  fi
fi
if [ -n "${SUPERSET_MCP_URL:-}" ]; then
  MCP_PART="${MCP_PART}  superset:
    type: streamable-http
    url: '\${SUPERSET_MCP_URL}'
    initTimeout: 30000
"
  if [ -n "${SUPERSET_MCP_TOKEN:-}" ]; then
    MCP_PART="${MCP_PART}    headers:
      Authorization: 'Bearer \${SUPERSET_MCP_TOKEN}'
"
  fi
fi

{
  printf "version: '1.2.8'\n"
  printf 'cache: true\n'
  printf 'interface: {}\n'
  printf 'endpoints:\n'
  printf '  custom:\n'
  printf "    - name: '%s'\n" "$LLM_NAME"
  printf '%s\n' "$API_KEY_LINE"
  printf "      baseURL: '\${LLM_BASE_URL}'\n"
  printf '      models:\n'
  printf '        default:\n'
  printf "          - '%s'\n" "$LLM_DEFAULT_MODEL"
  OLDIFS=$IFS
  IFS=,
  for m in $LLM_MODELS; do
    if [ "$m" != "$LLM_DEFAULT_MODEL" ]; then
      printf "          - '%s'\n" "$m"
    fi
  done
  IFS=$OLDIFS
  printf '        fetch: false\n'
  printf '      titleConvo: false\n'
  if [ -n "$MCP_PART" ]; then
    printf 'mcpServers:\n'
    printf '%s' "$MCP_PART"
  fi
} > "$TMP_FILE"
mv "$TMP_FILE" "$CONFIG_FILE"

# ---------- post-check: validate the generated file against LibreChat's schema
node -e '
var fs = require("fs");
var yaml = require("js-yaml");
var dataProvider = require("librechat-data-provider");
var file = process.env.CONFIG_FILE;
var raw = fs.readFileSync(file, "utf8");
var doc;
try {
  doc = yaml.load(raw);
} catch (e) {
  console.error("librechat-boot: generated config is not valid YAML: " + e.message);
  process.exit(1);
}
var result = dataProvider.configSchema.strict().safeParse(doc);
if (!result.success) {
  console.error("librechat-boot: generated config failed LibreChat schema validation: " + JSON.stringify(result.error.issues));
  process.exit(1);
}
'

# ---------- run ---------------------------------------------------------------
exec node server/index.js
