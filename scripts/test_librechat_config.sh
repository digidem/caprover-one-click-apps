#!/usr/bin/env bash
# Generator test for the LibreChat one-click app (spec 5.2). Thin wrapper:
# all logic lives in test_librechat_config.js (npm run test_librechat).
# Needs docker. Not part of validate_apps (spec 5.1).
set -euo pipefail
exec node "$(dirname "$0")/../scripts/test_librechat_config.js"
