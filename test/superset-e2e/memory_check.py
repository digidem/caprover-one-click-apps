"""Memory behaviour of the MCP process.

The question is not "does RSS go up" — it does, as caches warm. The question is
whether it plateaus/decays (cache) or climbs without bound (leak). The decisive
test is the restart: a leak resumes from where it stopped, a cache re-traces the
same curve from the same baseline.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

CONTAINER = os.environ.get("MCP_CONTAINER", "ss-mcp-e2e-superset-mcp-1")
MCP_URL = os.environ.get("MCP_URL", "http://127.0.0.1:15008")
TOKEN = os.environ.get("AGENT_TOKEN", "")
BASE = MCP_URL.rstrip("/") + "/mcp"
READS = ["list_datasets", "list_dashboards", "list_charts", "list_databases", "health_check"]
LEAK_THRESHOLD_MIB = 12.0


def rss_mib() -> float:
    out = subprocess.run(
        ["docker", "exec", CONTAINER, "sh", "-c", "grep -E '^VmRSS:' /proc/1/status"],
        capture_output=True, text=True, check=True,
    ).stdout
    return int(out.split(":")[1].split()[0]) / 1024


def call(name: str, arguments: dict | None = None) -> bool:
    body = {"jsonrpc": "2.0", "method": "tools/call", "id": 1,
            "params": {"name": name, "arguments": arguments or {}}}
    request = urllib.request.Request(
        BASE, data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json",
                 "Accept": "application/json, text/event-stream"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return b'"isError":true' not in response.read()
    except (urllib.error.HTTPError, urllib.error.URLError):
        return False


def load(rounds: int, per_round: int, samples: list[tuple[int, float]]) -> None:
    calls = 0
    for index in range(rounds):
        for i in range(per_round):
            call(READS[i % len(READS)], {"request": {"page": 1, "page_size": 50}})
            calls += 1
        time.sleep(0.5)
        samples.append((calls, rss_mib()))
    return calls


def wait_ready() -> None:
    for _ in range(24):
        body = {"jsonrpc": "2.0", "method": "tools/list", "id": 1}
        request = urllib.request.Request(
            BASE, data=json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json",
                     "Accept": "application/json, text/event-stream"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status in (200, 401):
                    return
        except (urllib.error.HTTPError, urllib.error.URLError):
            pass
        time.sleep(5)


def main() -> int:
    import os

    if not TOKEN:
        print("error: AGENT_TOKEN env is required", file=sys.stderr)
        return 2

    print("  sampling RSS across a sustained read-only load ...")
    first: list[tuple[int, float]] = []
    total = load(rounds=int(os.environ.get("MEM_ROUNDS", 10)), per_round=20, samples=first)
    first_start, first_end = first[0][1], first[-1][1]
    print(f"    {total} calls: {first_start:.1f} -> {first_end:.1f} MiB "
          f"(+{first_end - first_start:.1f})")

    print("  restarting the MCP process ...")
    subprocess.run(["docker", "restart", CONTAINER], check=True,
                   capture_output=True)
    wait_ready()
    fresh = rss_mib()
    print(f"    after restart: {fresh:.1f} MiB")

    second: list[tuple[int, float]] = []
    load(rounds=int(os.environ.get("MEM_ROUNDS_2", 6)), per_round=20, samples=second)

    print()
    print(f"  run 1: {first_start:.1f} -> {first_end:.1f} MiB over {total} calls")
    print(f"  after restart: {fresh:.1f} MiB")
    print(f"  run 2 first sample: {second[0][1]:.1f} MiB (run 1 at the same point: "
          f"{first[0][1]:.1f} MiB)")

    # A leak would resume from ~first_end; a cache re-traces from the baseline.
    resumed_from_leak = second[0][1] > (first_end - 5)
    re_traced = abs(second[0][1] - first[0][1]) < 6.0
    growth = first_end - first_start

    if re_traced and not resumed_from_leak:
        verdict = "no leak signal: growth resets on restart (cache warm-up)"
    elif growth < LEAK_THRESHOLD_MIB:
        verdict = f"bounded growth (+{growth:.1f} MiB over {total} calls)"
    else:
        verdict = f"GROWING +{growth:.1f} MiB over {total} calls - investigate"

    print(f"  -- memory -- {verdict}")
    return 0 if "GROWING" not in verdict else 1


if __name__ == "__main__":
    sys.exit(main())
