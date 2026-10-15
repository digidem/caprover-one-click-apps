#!/usr/bin/env python3
# Mint HS256 MCP tokens for the Superset MCP server (spec 6.4, D10).
# Secret comes from env MCP_JWT_SECRET (required, never printed).
# Scopes are a global JWT admission requirement only on 6.1.0: MCP_REQUIRED_SCOPES
# is checked by the verifier, but no per-tool scope enforcement exists, so
# "mcp:read" does NOT make the token read-only. Authorization is the FAB role of
# the process's MCP_DEV_USERNAME plus object ownership.
# Usage:
#   MCP_JWT_SECRET=... python3 scripts/superset_mint_mcp_token.py \
#     --sub librechat-agent --iss superset --aud superset --scopes 'mcp:read' --days 30
# Prints the token to stdout and nothing else.
import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time

def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--sub", default="librechat-agent")
    p.add_argument("--iss", default="superset")
    p.add_argument("--aud", default="superset")
    p.add_argument("--scopes", default="mcp:read")
    p.add_argument("--days", type=int, default=365)
    args = p.parse_args()
    secret = os.environ.get("MCP_JWT_SECRET")
    if not secret:
        print("error: MCP_JWT_SECRET env is required", file=sys.stderr)
        return 1
    now = int(time.time())
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "sub": args.sub,
        "iss": args.iss,
        "aud": args.aud,
        "scope": args.scopes,
        "exp": now + args.days * 86400,
        "iat": now,
    }
    h = b64url(json.dumps(header, separators=(",", ":")).encode())
    b = b64url(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = h + "." + b
    sig = b64url(hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest())
    print(signing_input + "." + sig)
    return 0

if __name__ == "__main__":
    sys.exit(main())
