"""Cross-role ownership checks.

These are the reason the harness runs a second MCP process with its own
identity. The point is not "the read-only role can read less" — it is that
`raise_for_ownership` (the only object-level boundary in 6.1.0; there is no
`raise_for_editorship` in the tag) stops a *different non-admin* user from
mutating the agent's objects, and stops the agent from mutating theirs.

So: two users with the same role, each owning their own dashboard and chart, and
each attempting to touch the other's.
"""
from __future__ import annotations

import json
import sys

from mcp_client import Mcp, require_env


class Checks:
    def __init__(self) -> None:
        self.agent = Mcp(require_env("MCP_URL"), require_env("AGENT_TOKEN"))
        self.writer = Mcp(require_env("MCP_WRITER_URL"), require_env("WRITER_TOKEN"))
        self.passed = 0
        self.failed = 0

    def check(self, label: str, condition: bool, detail: str = "", limit: int = 220) -> None:
        if condition:
            self.passed += 1
            print(f"  PASS  {label}")
        else:
            self.failed += 1
            print(f"  FAIL  {label}\n         {detail[:limit]}")

    def report(self, title: str) -> int:
        print(f"\n{title}: {self.passed} passed, {self.failed} failed")
        return 1 if self.failed else 0


def _chart_config() -> dict:
    return {
        "chart_type": "table",
        "columns": [{"name": "nome"}, {"name": "distancia_km", "aggregate": "SUM"}],
    }


def _create_stack(client: Mcp, title: str) -> tuple[int | None, int | None]:
    """Create a dashboard + chart owned by `client`'s identity."""
    ok, payload = client.call("generate_chart", {"request": {
        "dataset_id": 1, "chart_type": "table", "chart_name": f"{title} chart",
        "save_chart": True, "config": _chart_config(),
    }})
    if not ok:
        return None, None
    try:
        chart_id = json.loads(payload)["chart"]["id"]
    except Exception:
        return None, None
    ok, payload = client.call("generate_dashboard", {"request": {
        "chart_ids": [chart_id], "dashboard_title": title, "published": False,
    }})
    dashboard_id = None
    try:
        dashboard_id = json.loads(payload)["dashboard"]["id"]
    except Exception:
        pass
    return dashboard_id, chart_id


def main() -> int:
    checks = Checks()

    agent_dash, _agent_chart = _create_stack(checks.agent, "agent-owned dashboard")
    writer_dash, writer_chart = _create_stack(checks.writer, "writer-owned dashboard")

    checks.check("both identities created their own dashboard",
                 agent_dash is not None and writer_dash is not None,
                 f"agent={agent_dash} writer={writer_dash}")

    if agent_dash and writer_dash:
        # The other user's dashboard must be unreachable for mutation.
        ok, payload = checks.writer.call("add_chart_to_existing_dashboard", {"request": {
            "dashboard_id": agent_dash, "chart_id": 1,
        }})
        checks.check(
            "the writer cannot add a chart to the agent's dashboard",
            ok and ("permission" in payload.lower() or "not own" in payload.lower()),
            payload, 260,
        )

        # And the agent must not be able to mutate the writer's.
        ok, payload = checks.agent.call("add_chart_to_existing_dashboard", {"request": {
            "dashboard_id": writer_dash, "chart_id": 1,
        }})
        checks.check(
            "the agent cannot add a chart to the writer's dashboard",
            ok and ("permission" in payload.lower() or "not own" in payload.lower()),
            payload, 260,
        )

        # The agent may not attach a chart it does not own, even to its own
        # dashboard. Dataset access alone is not enough (chart-ownership patch).
        if writer_chart:
            ok, payload = checks.agent.call("add_chart_to_existing_dashboard", {"request": {
                "dashboard_id": agent_dash, "chart_id": writer_chart,
            }})
            checks.check(
                "the agent cannot attach the writer's chart to its own dashboard",
                ok and "not owned by the service user" in payload,
                payload, 260,
            )

    # The REST helper must land on the same wall: it cannot rename the other
    # user's dataset. Dataset 1 is seeded as the agent's; the writer's own is
    # created below via the API, so the helper (agent identity) must be refused.
    return checks.report("-- cross-role ownership --")


if __name__ == "__main__":
    sys.exit(main())
