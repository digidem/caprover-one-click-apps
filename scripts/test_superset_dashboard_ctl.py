#!/usr/bin/env python3
"""Contract tests for scripts/superset_dashboard_ctl.py.

These need NO Superset instance: they pin the parts of the helper that encode
hard-won findings from the tag-6.1.0 audit and the live e2e run, so a future
refactor cannot silently reintroduce those bugs.

Covered invariants:
  1. Only narrow, hard-coded operations are exposed. No generic URL/PUT/DELETE
     and no arbitrary SQL entry points exist in the CLI surface.
  2. Ownership is never used as an authorisation decision, and no Admin is
     required: Superset's raise_for_ownership is the only backstop.
  3. CSRF ordering: the token is fetched BEFORE the Cookie header is built
     (the csrf response re-issues the session cookie).
  4. The session cookie is replayed by hand, not via a cookie jar (Superset
     marks it Secure and urllib drops Secure cookies over plain http://).
  5. Layout transformations preserve the invariants that the real instance
     enforces: ROOT has exactly one child; TABS accepts only TAB children; a
     GRID never becomes a TAB child; no dangling child ids; full ancestor chains.
  6. A dashboard description is refused (DashboardPutSchema has no such field).
  7. Metadata is carried through layout writes, and malformed metadata aborts
     instead of resetting the dashboard.
  8. Hard deletes are described as hard, never as soft/trashed.

Usage: python3 scripts/test_superset_dashboard_ctl.py   (exit 0 = pass)
"""
from __future__ import annotations

import importlib.util
import inspect
import json
import re
import sys
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent
SCRIPT = REPO / "superset_dashboard_ctl.py"

spec = importlib.util.spec_from_file_location("sdctl", SCRIPT)
sdctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdctl)  # type: ignore[union-attr]

failures: list[str] = []


def check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS  {label}")
    else:
        failures.append(label)
        print(f"  FAIL  {label}" + (f"\n         {detail}" if detail else ""))


def section(title: str) -> None:
    print(f"\n{title}")


def main() -> int:
    source = SCRIPT.read_text(encoding="utf-8")
    parser = sdctl._build_parser()
    choices = set(parser._subparsers._group_actions[0].choices)

    # ---- 1. narrow surface -------------------------------------------------
    section("1. operation surface is narrow")
    expected = {
        "rename-dashboard", "rename-dataset", "rename-chart", "set-filters",
        "create-tab", "move-chart", "add-chart", "remove-chart",
        "delete-chart", "delete-dashboard", "delete-dataset", "show",
    }
    check("exactly the documented commands exist", choices == expected,
          f"got {sorted(choices)}")
    for banned in ("exec-sql", "sql", "set-position-json", "put", "raw"):
        check(f"no generic/unsafe '{banned}' command", banned not in choices)

    # A command that accepted an arbitrary path or SQL would show up as an
    # argument literally named one of these.
    banned_args = {"sql", "url", "path", "endpoint", "body", "payload"}
    leaked: list[str] = []
    for name, sub in parser._subparsers._group_actions[0].choices.items():
        for action in sub._actions:
            if action.dest in banned_args:
                leaked.append(f"{name} --{action.dest}")
    check("no command takes a raw SQL/URL/path/body argument", not leaked,
          f"leaked: {leaked}")

    # ---- 2. ownership is reported, never used to authorise -----------------
    section("2. ownership is not an authorisation decision")
    check("no ownership preflight that refuses writes",
          not hasattr(sdctl, "_require_ownership"),
          "_require_ownership still exists; the REST GETs expose no username, so a "
          "username comparison would refuse legitimate objects")
    check("ownership is only reported", hasattr(sdctl, "_report_ownership"))
    report_src = inspect.getsource(sdctl._report_ownership)
    check("_report_ownership never raises",
          "raise" not in report_src.replace("raises", "").replace("raise_for", ""))

    # ---- 3 & 4. CSRF and cookie handling ----------------------------------
    section("3. CSRF / session cookie ordering")
    request_src = inspect.getsource(sdctl.Client._request)
    csrf_at = request_src.index("self.csrf_token()")
    cookie_at = request_src.index('headers["Cookie"]')
    check("CSRF token fetched before the Cookie header is built",
          csrf_at < cookie_at,
          "the csrf response re-issues the session cookie, so the token must be "
          "fetched first or Superset answers 'The CSRF session token is missing'")
    check("Referer is sent (WTF_CSRF_SSL_STRICT defaults True)",
          'headers.setdefault("Referer"' in request_src)
    init_src = inspect.getsource(sdctl.Client.__init__)
    check("no cookie jar is used (Secure cookies are dropped over plain http)",
          "CookieJar" not in init_src and "HTTPCookieProcessor" not in init_src)
    check("the raw Set-Cookie value is captured",
          "Set-Cookie" in request_src and hasattr(sdctl.Client, "_capture_session_cookie"))
    check("X-CSRFToken header is used", 'headers["X-CSRFToken"]' in request_src)
    check("using the dedicated filters endpoint",
          "/filters" in inspect.getsource(sdctl.Client.put_filters))

    # ---- 5. layout invariants ---------------------------------------------
    section("4. layout invariants")

    def grid_layout() -> dict:
        return {
            "ROOT_ID": {"id": "ROOT_ID", "children": ["GRID_ID"], "type": "ROOT"},
            "GRID_ID": {"id": "GRID_ID", "children": ["ROW-1"], "type": "GRID", "meta": {}},
            "ROW-1": {"id": "ROW-1", "children": ["COLUMN-1"], "type": "ROW", "meta": {}},
            "COLUMN-1": {"id": "COLUMN-1", "children": ["CHART-9"], "type": "COLUMN", "meta": {}},
            "CHART-9": {"id": "CHART-9", "children": [], "type": "CHART", "meta": {"chartId": 9}},
            "DASHBOARD_VERSION_KEY": "v2",
        }

    layout = grid_layout()
    sdctl._ensure_tabs(layout)
    roots = [c for c in layout["ROOT_ID"]["children"] if c in layout]
    check("ROOT has exactly one child after conversion to tabs", len(roots) == 1,
          f"children={layout['ROOT_ID']['children']}")
    types_under_root = {layout[c]["type"] for c in roots}
    check("ROOT's child is TABS or GRID", types_under_root <= {"TABS", "GRID"},
          f"got {types_under_root}")
    # the grid's content must have been carried into a tab, not orphaned
    tabs = [k for k, v in layout.items() if isinstance(v, dict) and v.get("type") == "TAB"]
    check("grid content moved into a TAB (not lost)",
          any("ROW-1" in (layout[t].get("children") or []) for t in tabs),
          "the first tab must inherit the grid's rows")
    check("the GRID component itself is removed when tabbed",
          "GRID_ID" not in layout,
          "a GRID is not a legal TAB child, so it must not remain referenced")
    check("chart 9 is still reachable", 9 in sdctl._chart_ids(layout))
    check("no dangling child ids after conversion",
          sdctl._dangling(layout) == [], f"dangling={sdctl._dangling(layout)}")
    sdctl._rebuild_parents(layout)
    chart = next(k for k, v in layout.items()
                 if isinstance(v, dict) and v.get("type") == "CHART")
    chain = layout[chart]["parents"]
    check("ancestor chain is complete (immediate parent first)",
          chain[:1] == ["COLUMN-1"] and "ROOT_ID" in chain[-1:],
          f"chains must run innermost-parent -> ROOT_ID, got {chain}")
    check("version marker survives", "DASHBOARD_VERSION_KEY" in layout)

    # removing the only chart must not leave dangling refs nor collapse tabs
    layout2 = grid_layout()
    sdctl._drop_component(layout2, "CHART-9")
    for key, widget in sdctl._widgets(layout2).items():
        children = widget.get("children") or []
        if "CHART-9" in children:
            layout2[key]["children"] = [c for c in children if c != "CHART-9"]
    sdctl._drop_empty_containers(layout2)
    check("no dangling ids after clearing a chart",
          sdctl._dangling(layout2) == [], f"dangling={sdctl._dangling(layout2)}")

    # tabbed dashboard: tab structure must survive emptying
    tabbed = grid_layout()
    sdctl._ensure_tabs(tabbed)
    sdctl._drop_component(tabbed, "CHART-9")
    for key, widget in sdctl._widgets(tabbed).items():
        children = widget.get("children") or []
        if "CHART-9" in children:
            tabbed[key]["children"] = [c for c in children if c != "CHART-9"]
    sdctl._drop_empty_containers(tabbed)
    root_children = [c for c in tabbed["ROOT_ID"]["children"] if c in tabbed]
    check("ROOT keeps a single child after the last chart is removed",
          len(root_children) == 1 and tabbed[root_children[0]]["type"] == "TABS",
          f"children={root_children} -> a ROOT with no valid child cannot render")

    # a chart must never be attached directly to TABS: TABS accepts only TAB
    # children. Check the actual code path used when --tab is omitted.
    for func in (sdctl.cmd_move_chart, sdctl.cmd_add_chart):
        text = inspect.getsource(func)
        reaches_tabs = bool(re.search(r"=\s*_ensure_tabs\(", text))
        check(f"{func.__name__} with no --tab uses the grid, never TABS",
              not reaches_tabs and "_ensure_grid(" in text,
              "attaching a ROW under TABS would create an unrenderable layout")

    # ---- 6 & 7 & 8. payload and semantics ---------------------------------
    section("5. payload and semantics")
    check("dashboard description is refused client-side",
          "DashboardPutSchema exposes no `description` field"
          in inspect.getsource(sdctl.cmd_rename_dashboard))
    check("layout write carries existing metadata",
          "existing_metadata" in inspect.getsource(sdctl._apply_layout)
          and "_metadata_payload" in inspect.getsource(sdctl._apply_layout))
    meta_src = inspect.getsource(sdctl._metadata_of)
    check("malformed JSON metadata aborts rather than resetting",
          "not valid JSON" in meta_src and "refusing to rewrite" in meta_src)
    check("non-object metadata aborts rather than resetting",
          "not a JSON object" in meta_src)
    check("filters use the deleted/modified/reordered diff",
          "reordered" in inspect.getsource(sdctl.cmd_set_filters))
    check("dataset delete checks dependants",
          "related_objects" in inspect.getsource(sdctl.cmd_delete_dataset))
    for command in (sdctl.cmd_delete_chart, sdctl.cmd_delete_dashboard,
                    sdctl.cmd_delete_dataset):
        text = inspect.getsource(command)
        check(f"{command.__name__} says deletes are permanent",
              "permanent" in text, "6.1.0 has no SOFT_DELETE; deletes are hard")
    # The tag has no soft delete, so the helper must never PROMISE it. Mentions
    # are legitimate when they deny it ("no trash", "no SOFT_DELETE").
    promising = [
        line for line in source.splitlines()
        if re.search(r"soft[- ]?delete", line, re.I)
        and not re.search(r"no soft|no SOFT_DELETE|permanent|hard", line, re.I)
    ]
    check("soft delete is never promised (only denied)", not promising,
          f"lines implying recoverability: {promising}")

    # ---- report -----------------------------------------------------------
    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {failures}")
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
