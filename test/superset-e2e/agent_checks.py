"""Checks that exercise the native 6.1.0 MCP tools as the agent identity.

Covers what docs/librechat-integrations.md section 8.1 records: the read side,
the write side, and the two denials that prove the role has no SQLLab /
SavedQuery reach.
"""
from __future__ import annotations

import json
import sys

from mcp_client import Mcp, require_env

AGENT_TOKEN = require_env("AGENT_TOKEN")
MCP_URL = require_env("MCP_URL")


class Checks:
    def __init__(self) -> None:
        self.client = Mcp(MCP_URL, AGENT_TOKEN)
        self.passed = 0
        self.failed = 0

    def check(self, label: str, condition: bool, detail: str = "", limit: int = 200) -> None:
        if condition:
            self.passed += 1
            print(f"  PASS  {label}")
        else:
            self.failed += 1
            print(f"  FAIL  {label}\n         {detail[:limit]}")

    def report(self, title: str) -> int:
        print(f"\n{title}: {self.passed} passed, {self.failed} failed")
        return 1 if self.failed else 0


def main() -> int:
    checks = Checks()
    client = checks.client

    # ---- discovery --------------------------------------------------------
    ok, payload = client.call("search_tools", {"query": "dashboard"})
    names = []
    try:
        names = [item.get("name") for item in json.loads(payload)]
    except Exception:
        pass
    checks.check("search_tools finds the dashboard tools",
                 ok and "list_dashboards" in names, payload)

    # ---- read side --------------------------------------------------------
    for tool, needle, label in (
        ("list_datasets", "e2e_frota", "list_datasets returns the granted dataset"),
        ("list_databases", "examples", "list_databases returns only the granted db"),
    ):
        ok, payload = client.call(tool, {"request": {"page": 1, "page_size": 50}})
        checks.check(label, ok and needle in payload, payload)

    for tool in ("list_dashboards", "list_charts", "get_instance_info", "health_check"):
        ok, payload = client.call(tool, {"request": {"page": 1, "page_size": 10}})
        checks.check(f"{tool} answers", ok, payload, 160)

    dataset_id = None
    ok, payload = client.call("list_datasets", {"request": {"page": 1, "page_size": 10}})
    try:
        dataset_id = json.loads(payload)["datasets"][0]["id"]
    except Exception:
        pass
    checks.check("dataset id resolved for later steps", dataset_id is not None)

    if dataset_id:
        ok, payload = client.call("get_dataset_info", {"request": {"identifier": dataset_id}})
        checks.check("get_dataset_info returns columns", ok and "columns" in payload, payload, 200)

    # ---- write side -------------------------------------------------------
    chart_config = {
        "chart_type": "table",
        "columns": [{"name": "nome"}, {"name": "distancia_km", "aggregate": "SUM"}],
    }
    ok, payload = client.call("generate_chart", {"request": {
        "dataset_id": dataset_id, "chart_type": "table", "chart_name": "e2e frota salvo",
        "save_chart": True, "config": chart_config,
    }})
    checks.check("generate_chart with save_chart=True succeeds", ok, payload, 200)
    chart_id = None
    try:
        chart_id = json.loads(payload)["chart"]["id"]
    except Exception:
        pass
    checks.check("a chart id came back", chart_id is not None, payload, 160)

    ok, payload = client.call("generate_dashboard", {"request": {
        "chart_ids": [chart_id] if chart_id else [], "dashboard_title": "e2e frota dash",
        "published": False,
    }} if chart_id else {})
    if chart_id:
        checks.check("generate_dashboard succeeds", ok, payload, 200)
        dashboard_id = None
        try:
            dashboard_id = json.loads(payload)["dashboard"]["id"]
        except Exception:
            pass
        checks.check("a dashboard id came back", dashboard_id is not None, payload, 160)

        ok, payload = client.call("add_chart_to_existing_dashboard", {"request": {
            "dashboard_id": dashboard_id, "chart_id": chart_id, "target_tab": None,
        }})
        checks.check(
            "add_chart_to_existing_dashboard reports the duplicate instead of failing",
            ok and ("already" in payload.lower() or "error" in payload.lower()),
            payload, 200,
        )

    # ---- the role must not reach these ------------------------------------
    for tool, needle, arguments in (
        ("execute_sql", "Permission denied",
         {"request": {"database_id": 1, "sql": "select 1"}}),
        ("save_sql_query", "Permission denied",
         {"request": {"label": "x", "sql": "select 1", "database_id": 1}}),
    ):
        ok, payload = client.call(tool, arguments)
        checks.check(f"{tool} is denied", ok and needle in payload, payload, 220)

    return checks.report("-- MCP (native tools) --")


if __name__ == "__main__":
    sys.exit(main())
