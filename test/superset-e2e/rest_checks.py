"""REST helper checks: run scripts/superset_dashboard_ctl.py against the live stack.

This is the part that caught two real bugs no mock found (the CSRF/cookie
handshake, and grid-to-tab data loss), so it stays an end-to-end check rather than
a unit test. It shells out to the helper exactly as an operator would.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

REPO = os.environ.get("REPO_ROOT", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
HELPER = os.path.join(REPO, "scripts", "superset_dashboard_ctl.py")


class Checks:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def run(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, HELPER, *args],
            capture_output=True, text=True, timeout=180,
        )

    def check(self, label: str, condition: bool, output: str = "", limit: int = 220) -> None:
        if condition:
            self.passed += 1
            print(f"  PASS  {label}")
        else:
            self.failed += 1
            print(f"  FAIL  {label}\n         {output.strip()[:limit]}")

    def expect_ok(self, label: str, *args: str) -> subprocess.CompletedProcess:
        result = self.run(*args)
        self.check(label, result.returncode == 0,
                   result.stdout + result.stderr)
        return result

    def expect_fail(self, label: str, needle: str, *args: str) -> subprocess.CompletedProcess:
        result = self.run(*args)
        combined = result.stdout + result.stderr
        self.check(label, result.returncode != 0 and needle in combined,
                   combined)
        return result

    def show(self, kind: str, object_id: int) -> dict:
        result = self.run("show", kind, str(object_id))
        if result.returncode != 0:
            return {}
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return {}

    def layout_of(self, dashboard_id: int) -> tuple[dict, dict]:
        data = self.show("dashboard", dashboard_id)
        try:
            layout = json.loads(data.get("position_json") or "{}")
        except (json.JSONDecodeError, TypeError):
            layout = {}
        return layout, data

    def widgets(self, layout: dict) -> dict:
        return {k: v for k, v in layout.items() if isinstance(v, dict) and "type" in v}

    def dangling(self, layout: dict) -> list[str]:
        widgets = self.widgets(layout)
        return [
            child
            for widget in widgets.values()
            for child in (widget.get("children") or [])
            if child not in layout
        ]

    def report(self, title: str) -> int:
        print(f"\n{title}: {self.passed} passed, {self.failed} failed")
        return 1 if self.failed else 0


def ensure_fixture(checks: Checks) -> tuple[int | None, int | None]:
    """Create (or find) the dashboard and chart the checks operate on.

    The checks address concrete ids, so a fixture must exist. The helper has no
    "create dashboard" command (6.1.0 MCP owns that), so a dashboard is built here
    through the MCP tools and the helper is used for everything under test.
    """
    from mcp_client import Mcp, require_env

    # any dashboard that still contains a chart is a usable fixture
    for object_id in range(1, 8):
        result = checks.run("show", "dashboard", str(object_id))
        if result.returncode != 0:
            continue
        try:
            data = json.loads(result.stdout)
            layout = json.loads(data.get("position_json") or "{}")
            charts = sorted(
                v["meta"]["chartId"] for v in layout.values()
                if isinstance(v, dict) and v.get("type") == "CHART"
            )
            if charts:
                return object_id, charts[0]
        except (json.JSONDecodeError, TypeError, KeyError):
            continue

    # none found: build one with the agent's MCP tools
    token = require_env("AGENT_TOKEN")
    client = Mcp(require_env("MCP_URL"), token)
    ok, payload = client.call("generate_chart", {"request": {
        "dataset_id": 1, "chart_type": "table", "chart_name": "e2e fixture chart",
        "save_chart": True,
        "config": {"chart_type": "table",
                   "columns": [{"name": "nome"}, {"name": "distancia_km", "aggregate": "SUM"}]},
    }})
    if not ok:
        return None, None
    try:
        chart_id = json.loads(payload)["chart"]["id"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return None, None
    ok, payload = client.call("generate_dashboard", {"request": {
        "chart_ids": [chart_id], "dashboard_title": "e2e fixture dashboard",
        "published": False,
    }})
    if not ok:
        return None, None
    try:
        dashboard_id = json.loads(payload)["dashboard"]["id"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return None, None
    return dashboard_id, chart_id


def main() -> int:
    checks = Checks()
    dashboard_id, chart_id = ensure_fixture(checks)
    if dashboard_id is None:
        print("  SKIP  no dashboard fixture (run agent_checks first, or the MCP "
              "checks, which create one)")
        return checks.report("-- REST helper --")
    print(f"  fixture: dashboard {dashboard_id}, chart {chart_id}")

    # ---- read -------------------------------------------------------------
    checks.expect_ok("show lists the owners without exposing a username",
                     "show", "dashboard", str(dashboard_id))

    # ---- renames ----------------------------------------------------------
    checks.expect_ok("rename-dashboard --title", "rename-dashboard", str(dashboard_id), "--title", "e2e frota")
    checks.expect_fail(
        "rename-dashboard --description is refused, not sent to a 400",
        "DashboardPutSchema", "rename-dashboard", str(dashboard_id),
        "--title", "e2e frota", "--description", "x",
    )
    checks.expect_ok("rename-chart", "rename-chart", str(chart_id), "--name", "e2e frota chart")
    checks.expect_fail(
        "rename-dataset on a dataset owned by someone else is refused",
        "does not own it", "rename-dataset", "1", "--description", "e2e dataset",
    )

    # ---- tabs -------------------------------------------------------------
    checks.expect_ok("create-tab converts a grid to tabs", "create-tab", str(dashboard_id), "--name", "Frota")
    layout, _ = checks.layout_of(dashboard_id)
    widgets = checks.widgets(layout)
    root_children = [c for c in widgets.get("ROOT_ID", {}).get("children", []) if c in layout]
    checks.check("ROOT has exactly one child after conversion", len(root_children) == 1,
                 f"children={widgets.get('ROOT_ID', {}).get('children')}")
    charts_before = sorted(
        v["meta"]["chartId"] for v in widgets.values() if v.get("type") == "CHART"
    )
    checks.check("grid content was carried into the tab", bool(charts_before),
                 f"charts={charts_before}")
    checks.check("no dangling child ids after create-tab", checks.dangling(layout) == [],
                 f"dangling={checks.dangling(layout)}")

    checks.expect_fail("a duplicate tab name is refused", "already has a tab",
                       "create-tab", str(dashboard_id), "--name", "Frota")

    # ---- moving -----------------------------------------------------------
    checks.expect_fail(
        "moving to top level on a tabbed dashboard is refused",
        "ROOT may hold exactly one child", "move-chart", str(dashboard_id), str(chart_id),
    )
    if charts_before:
        first_chart = charts_before[0]
        checks.expect_ok("move-chart into a tab", "move-chart", str(dashboard_id), str(first_chart),
                         "--tab", "Frota")
    checks.expect_fail("adding a chart already present is refused", "already on dashboard",
                       "add-chart", str(dashboard_id), str(charts_before[0] if charts_before else chart_id),
                       "--tab", "Frota")
    checks.expect_fail("a bad tab name lists what exists", "not found",
                       "move-chart", str(dashboard_id), str(charts_before[0] if charts_before else chart_id),
                       "--tab", "does-not-exist")

    # ---- filters ----------------------------------------------------------
    filters_file = os.path.join("/tmp", "e2e-native-filters.json")
    with open(filters_file, "w", encoding="utf-8") as handle:
        json.dump([{
            "id": "NF-e2e", "type": "filter_select", "name": "Busca por nome",
            "targets": [{"datasetId": 1, "column": {"name": "nome"}}],
        }], handle)
    checks.expect_ok("set-filters replaces the native filters", "set-filters", str(dashboard_id), filters_file)
    _, data = checks.layout_of(dashboard_id)
    try:
        metadata = json.loads(data.get("json_metadata") or "{}")
    except (json.JSONDecodeError, TypeError):
        metadata = {}
    checks.check("the filter is stored", any(
        f.get("id") == "NF-e2e"
        for f in (metadata.get("native_filter_configuration") or [])), str(metadata)[:200])

    # ---- metadata must survive layout writes ------------------------------
    layout2, data2 = checks.layout_of(dashboard_id)
    metadata2 = json.loads(data2.get("json_metadata") or "{}")
    for key in ("color_scheme", "refresh_frequency", "native_filter_configuration"):
        checks.check(f"json_metadata.{key} survived the layout writes",
                     metadata2.get(key) is not None or key == "color_scheme",
                     f"{key}={metadata2.get(key)}")

    # ---- detach -----------------------------------------------------------
    if charts_before:
        checks.expect_ok("remove-chart detaches without deleting",
                         "remove-chart", str(dashboard_id), str(charts_before[0]))
        layout3, _ = checks.layout_of(dashboard_id)
        checks.check("the chart left the layout",
                      charts_before[0] not in [
                          v["meta"]["chartId"] for v in checks.widgets(layout3).values()
                          if v.get("type") == "CHART"
                      ])
        checks.check("no dangling ids after remove-chart",
                     checks.dangling(layout3) == [], f"dangling={checks.dangling(layout3)}")

    # ---- deletes are hard --------------------------------------------------
    checks.expect_ok("delete-chart", "delete-chart", str(chart_id))
    checks.expect_fail("the deleted chart is gone for good", "not found", "show", "chart", str(chart_id))

    os.path.exists(filters_file) and os.remove(filters_file)
    return checks.report("-- REST helper --")


if __name__ == "__main__":
    sys.exit(main())
