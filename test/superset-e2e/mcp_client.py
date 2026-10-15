"""Minimal streamable-HTTP MCP client, so the e2e checks need no SDK.

Mirrors what LibreChat does: POST /mcp with a Bearer token, parse the SSE
`data:` frames, ignore notifications, pick the frame carrying our request id.

Usage as a library:
    mcp = Mcp(token)
    ok, payload = mcp.call("list_datasets", {"request": {"page": 1, "page_size": 10}})
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request


class Mcp:
    def __init__(self, base: str, token: str, timeout: int = 120):
        self.base = base.rstrip("/") + "/mcp"
        self.token = token
        self.timeout = timeout
        self._next_id = 1

    def call(self, name: str, arguments: dict | None = None) -> tuple[bool, str]:
        """Call a tool. Returns (succeeded, text_or_error)."""
        request_id = self._next_id
        self._next_id += 1
        body = {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": request_id,
            "params": {"name": name, "arguments": arguments or {}},
        }
        request = urllib.request.Request(
            self.base,
            data=json.dumps(body).encode(),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read().decode()
        except urllib.error.HTTPError as exc:
            return False, f"HTTP {exc.code}: {exc.read().decode()[:200]}"
        except urllib.error.URLError as exc:
            return False, f"unreachable: {exc.reason}"

        result = None
        for line in raw.splitlines():
            if not line.startswith("data: "):
                continue
            try:
                frame = json.loads(line[6:])
            except json.JSONDecodeError:
                continue
            if frame.get("id") == request_id:
                result = frame
                break
        if result is None:
            return False, "no result frame in response"
        if "error" in result:
            return False, str(result["error"])
        payload = result.get("result", {})
        texts = [c.get("text", "") for c in payload.get("content", []) if c.get("type") == "text"]
        return (not payload.get("isError", False)), (texts[0] if texts else "")


def require_env(name: str) -> str:
    import os

    value = os.environ.get(name, "")
    if not value:
        print(f"error: {name} env is required", file=sys.stderr)
        sys.exit(2)
    return value
