#!/usr/bin/env python3
# Semantic REST helper for the LibreChat agent account on Superset 6.1.0.
#
# Covers the operations the 24 native 6.1.0 MCP tools cannot do: rename/describe
# dashboards, charts and datasets; create a tab; move a chart into a tab;
# reorder/remove a layout component; set native filters; delete an owned chart
# or dataset.
#
# Design rules (see docs/librechat-integrations.md section 1):
#   * Only hard-coded, narrow, semantic operations. No generic URL/PUT/DELETE,
#     no arbitrary SQL.
#   * Every mutation preflights ownership and then still relies on Superset's
#     command layer (raise_for_ownership) as the authoritative backstop. There is
#     no raise_for_editorship in 6.1.0: ownership is the only boundary, and only
#     Admin bypasses it. We never grant Admin.
#   * CSRF is enabled in stock 6.1.0 (WTF_CSRF_ENABLED=True,
#     BaseSupersetApiMixin.csrf_exempt=False, CRUD not in WTF_CSRF_EXEMPT_LIST),
#     so we keep a cookie session and send X-CSRFToken on mutating calls.
#   * position_json editing alone does NOT detach a chart: BaseDAO.update is a
#     plain setattr, so the dashboard_slices M2M is untouched. Layout changes that
#     change membership go through json_metadata.positions, which
#     DashboardDAO.set_dash_metadata uses to rebuild dashboard.slices and rewrite
#     position_json in one transaction.
#
# Usage:
#   SUPERSET_URL=https://superset.example.com \
#   SUPERSET_USERNAME=librechat-agent SUPERSET_PASSWORD=... \
#   python3 scripts/superset_dashboard_ctl.py create-tab 6 --name "Distancias"
#
# Credentials come from env only and are never printed. Python 3.11+, stdlib only.
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 60

ROOT = "ROOT"
GRID = "GRID"
TABS = "TABS"
TAB = "TAB"
CHART = "CHART"
COLUMN = "COLUMN"
ROW = "ROW"
HEADER = "HEADER"
DIVIDER = "DIVIDER"
MARKDOWN = "MARKDOWN"

# Component *ids* used by Superset layout payloads (distinct from the types above).
ROOT_ID_KEY = "ROOT_ID"
GRID_ID_KEY = "GRID_ID"
TABS_ID_KEY = "TABS_ID"

# Only these component types are recognised; anything else in a stored layout is
# refused rather than silently carried through a rewrite.
KNOWN_TYPES = frozenset({ROOT, GRID, TABS, TAB, CHART, COLUMN, ROW, MARKDOWN, HEADER, DIVIDER})


class SupersetError(Exception):
    """A refused, not-found or failed operation. Carries the HTTP status."""

    def __init__(self, message: str, status: int = 0) -> None:
        super().__init__(message)
        self.status = status


def _log(message: str) -> None:
    print(message, file=sys.stderr)


class Client:
    """Authenticated session against the Superset REST API."""

    def __init__(self, base: str, username: str, password: str) -> None:
        self.base = base.rstrip("/")
        self._username = username
        self._password = password
        self._token: str | None = None
        self._csrf: str | None = None
        self._session_cookie: str | None = None
        # No cookie jar on purpose. Flask's session cookie is signed and
        # `Secure`, so (a) urllib's jar refuses to replay it over plain http://,
        # and (b) a jar that does hold several cookies emits its own Cookie
        # header, which races the explicit one set below. The latest cookie value
        # is captured from the response and replayed by hand - that is the one
        # the CSRF token was minted for.
        self._opener = urllib.request.build_opener()

    # ---- low level -----------------------------------------------------

    def _request(self, method: str, path: str, *, body=None, auth: bool = True,
                 csrf: bool = False, form: bool = False) -> tuple[int, object]:
        url = path if path.startswith("http") else f"{self.base}{path}"
        data: bytes | None = None
        headers = {"Accept": "application/json"}
        if body is not None:
            if form:
                data = urllib.parse.urlencode(body).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                data = json.dumps(body).encode()
                headers["Content-Type"] = "application/json"
        if auth:
            if not self._token:
                self.login()
            headers["Authorization"] = f"Bearer {self._token}"
            # Flask-WTF's WTF_CSRF_SSL_STRICT (default True) requires a
            # same-origin Referer on HTTPS mutating requests. Sending it always
            # keeps the helper working behind TLS and is harmless on plain HTTP.
            headers.setdefault("Referer", f"{self.base}/")
        # Fetch the CSRF token FIRST: its response also re-issues the session
        # cookie, and the token is only valid together with the cookie it was
        # minted for. Building the Cookie header before this would send a stale
        # cookie and Superset answers "The CSRF session token is missing".
        if csrf:
            headers["X-CSRFToken"] = self.csrf_token()
        # The session cookie is replayed by hand, not only via the cookie jar:
        # Superset marks it `Secure`, and http.cookiejar will not send a Secure
        # cookie back over plain http:// - which is exactly how a local or
        # overlay-network Superset is reached. Verified against a real 6.1.0.
        if self._session_cookie:
            headers["Cookie"] = self._session_cookie
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self._opener.open(request, timeout=TIMEOUT) as response:
                raw = response.read().decode()
                set_cookie = response.headers.get("Set-Cookie")
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode()
            set_cookie = exc.headers.get("Set-Cookie")
            if set_cookie:
                self._capture_session_cookie(set_cookie)
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                parsed = raw
            return exc.code, parsed
        except urllib.error.URLError as exc:
            raise SupersetError(f"{method} {path} unreachable: {exc.reason}") from exc
        if set_cookie:
            self._capture_session_cookie(set_cookie)
        try:
            return 200, json.loads(raw)
        except json.JSONDecodeError:
            return 200, raw

    def _capture_session_cookie(self, set_cookie: str) -> None:
        """Keep the `name=value` pair of the session cookie, ignoring attributes."""
        first = set_cookie.split(";", 1)[0].strip()
        if "=" in first:
            self._session_cookie = first

    def login(self) -> None:
        status, body = self._request(
            "POST", "/api/v1/security/login",
            body={"username": self._username, "password": self._password, "provider": "db"},
            auth=False,
        )
        if status != 200:
            raise SupersetError(f"login failed with HTTP {status}: {_short(body)}", status)
        token = body.get("access_token") if isinstance(body, dict) else None
        if not token:
            raise SupersetError("login response has no access_token", status)
        self._token = token

    def csrf_token(self) -> str:
        if self._csrf is None:
            status, body = self._request("GET", "/api/v1/security/csrf_token/")
            if status != 200 or not isinstance(body, dict):
                raise SupersetError(f"csrf token fetch failed with HTTP {status}: {_short(body)}", status)
            self._csrf = body.get("result") or ""
            if not self._csrf:
                raise SupersetError("csrf token endpoint returned an empty token", status)
        return self._csrf

    # ---- typed helpers -------------------------------------------------

    def get(self, kind: str, object_id: int) -> dict:
        status, body = self._request("GET", f"/api/v1/{kind}/{object_id}")
        if status == 404:
            raise SupersetError(f"{kind} {object_id} not found", 404)
        if status != 200:
            raise SupersetError(f"reading {kind} {object_id} failed with HTTP {status}: {_short(body)}", status)
        result = body.get("result", body) if isinstance(body, dict) else {}
        if not isinstance(result, dict):
            raise SupersetError(f"unexpected payload for {kind} {object_id}")
        return result

    def put(self, kind: str, object_id: int, payload: dict) -> dict:
        status, body = self._request(
            "PUT", f"/api/v1/{kind}/{object_id}", body=payload, csrf=True
        )
        return _map_status(kind, object_id, "update", status, body)

    def put_filters(self, dashboard_id: int, body: dict) -> dict:
        """PUT /api/v1/dashboard/<pk>/filters — the dedicated native-filter diff."""
        status, out = self._request(
            "PUT", f"/api/v1/dashboard/{dashboard_id}/filters", body=body, csrf=True
        )
        return _map_status("dashboard", dashboard_id, "set native filters", status, out)

    def delete(self, kind: str, object_id: int, payload: dict | None = None) -> dict:
        status, body = self._request(
            "DELETE", f"/api/v1/{kind}/{object_id}", body=payload, csrf=True
        )
        return _map_status(kind, object_id, "delete", status, body)


def _short(value: object) -> str:
    text = value if isinstance(value, str) else json.dumps(value)
    return text[:300]


def _map_status(kind: str, object_id: int, action: str, status: int, body: object) -> dict:
    if 200 <= status < 300:
        return body if isinstance(body, dict) else {"raw": body}
    if status == 403:
        raise SupersetError(
            f"DENIED {action} {kind} {object_id}: the agent account does not own it. "
            "Superset 6.1.0 checks ownership (raise_for_ownership) on every mutation "
            "path; only Admin bypasses it. Ask an Admin to transfer ownership or to "
            "perform this step.",
            403,
        )
    if status == 404:
        raise SupersetError(f"NOT FOUND {action} {kind} {object_id}", 404)
    raise SupersetError(f"FAILED {action} {kind} {object_id} (HTTP {status}): {_short(body)}", status)


# ---- ownership preflight --------------------------------------------------


def _owner_identities(result: dict) -> list[str]:
    """Best-effort owner identifiers from a GET result.

    The REST GET serializers do NOT expose usernames: charts expose
    `owners.id/first_name/last_name/email` (`superset/charts/api.py` list_columns)
    and datasets similar, while dashboards expose nested user objects. There is no
    "who am I" endpoint either. So this cannot reliably answer "am I an owner?",
    and comparing a first name or email against the login username would refuse
    legitimate objects.

    It is therefore used only to *report* who owns an object, never to authorise.
    Superset's command layer (`raise_for_ownership`) is the authority, and it
    reloads the resource and checks the real user against real owners.
    """
    owners = result.get("owners") or []
    found: list[str] = []
    for owner in owners:
        if isinstance(owner, dict):
            value = (
                owner.get("username")
                or owner.get("email")
                or " ".join(
                    part for part in (owner.get("first_name"), owner.get("last_name")) if part
                )
                or owner.get("id")
            )
            if value:
                found.append(str(value))
        elif owner is not None:
            found.append(str(owner))
    return found


def _report_ownership(kind: str, object_id: int, result: dict) -> None:
    """Log the owners for the operator. This is never an authorisation decision."""
    names = _owner_identities(result)
    if names:
        _log(f"info: {kind} {object_id} is owned by {', '.join(names)}")


# ---- layout helpers -------------------------------------------------------


def _load_layout(result: dict) -> dict:
    raw = result.get("position_json")
    if not raw:
        return {}
    if isinstance(raw, dict):
        return raw
    try:
        layout = json.loads(raw)
    except (json.JSONDecodeError, TypeError) as exc:
        raise SupersetError(f"dashboard position_json is malformed JSON: {exc}") from exc
    if not isinstance(layout, dict):
        raise SupersetError("dashboard position_json is not an object")
    unknown = sorted({v.get("type") for v in layout.values()
                      if isinstance(v, dict) and v.get("type") not in KNOWN_TYPES})
    if unknown:
        raise SupersetError(
            f"layout contains unrecognised component types {unknown}; refusing to "
            "rewrite it so existing structure is preserved"
        )
    return layout


def _widgets(layout: dict) -> dict:
    return {k: v for k, v in layout.items() if isinstance(v, dict) and "type" in v}


def _children_of(layout: dict, component_id: str) -> list[str]:
    widget = _widgets(layout).get(component_id, {})
    return [c for c in (widget.get("children") or []) if c in layout]


def _charts(layout: dict) -> dict[int, str]:
    """Map chartId -> component id for every CHART component in the layout."""
    found: dict[int, str] = {}
    for key, widget in _widgets(layout).items():
        if widget.get("type") != CHART:
            continue
        chart_id = (widget.get("meta") or {}).get("chartId")
        if chart_id is None:
            continue
        try:
            found[int(chart_id)] = key
        except (TypeError, ValueError):
            continue
    return found


def _all_tabs(layout: dict) -> list[tuple[str, str | None]]:
    """Return (tab_id, display_name) for every TAB component."""
    return [
        (key, (widget.get("meta") or {}).get("text"))
        for key, widget in _widgets(layout).items()
        if widget.get("type") == TAB
    ]


def _find_tab(layout: dict, name_or_id: str) -> str | None:
    for key, label in _all_tabs(layout):
        if key == name_or_id or (label is not None and str(label) == name_or_id):
            return key
    return None


def _rebuild_parents(layout: dict) -> dict:
    """Recompute each component's `parents` as the full ancestor chain.

    Superset stores the whole path, innermost parent first
    (ROOT_ID -> GRID_ID -> ROW -> COLUMN -> CHART becomes
    ["COLUMN-x", "ROW-x", "GRID_ID", "ROOT_ID"]), and the frontend consumes that
    chain for tab navigation and filter scopes
    (superset-frontend updateComponentParentsList). Recording only the immediate
    parent leaves the chain truncated, so it is rebuilt by walking upwards.
    """
    parent_of: dict[str, str | None] = {}
    for key, widget in _widgets(layout).items():
        for child in widget.get("children") or []:
            if child in layout:
                parent_of[child] = key            # a component has one parent

    root = ROOT_ID_KEY if ROOT_ID_KEY in layout else next(iter(_widgets(layout)), None)

    def chain_of(component_id: str, seen: set[str]) -> list[str]:
        chain: list[str] = []
        current = parent_of.get(component_id)
        while current is not None and current not in seen:
            seen.add(current)
            chain.append(current)
            current = parent_of.get(current)
        return chain

    for key in list(_widgets(layout)):
        widget = layout[key]
        if key == root:
            widget["parents"] = []
            continue
        widget["parents"] = chain_of(key, {key})
    return layout


def _drop_component(layout: dict, component_id: str) -> None:
    """Remove a component and every descendant. Callers prune via
    `_drop_empty_containers`, which preserves the top-level tab structure."""
    for key in [component_id, *_descendants(layout, component_id)]:
        layout.pop(key, None)


def _descendants(layout: dict, component_id: str) -> list[str]:
    out: list[str] = []
    frontier = list(_children_of(layout, component_id))
    while frontier:
        current = frontier.pop()
        if current in out or current not in layout:
            continue
        out.append(current)
        frontier.extend(_children_of(layout, current))
    return out


def _positions_from_layout(layout: dict) -> dict:
    """The `positions` payload handed to Superset.

    The version marker is KEPT: `DashboardDAO.set_dash_metadata` rewrites the
    dashboard's `position_json` from this dict verbatim, so dropping the marker
    here would strip it from the stored layout.
    """
    return dict(layout)


def _ensure_tabs(layout: dict) -> str:
    """Make sure a TABS container exists as the sole ROOT child. Returns its id."""
    widgets = _widgets(layout)
    if not widgets:
        raise SupersetError("dashboard has an empty layout; use generate_dashboard first")
    root_children = _children_of(layout, ROOT_ID_KEY)
    tabs_id = None
    for child in root_children:
        if widgets.get(child, {}).get("type") == TABS:
            tabs_id = child
            break
    if tabs_id is None:
        tabs_id = TABS_ID_KEY
        layout[tabs_id] = {
            "children": [],
            "id": tabs_id,
            "meta": {},
            "type": TABS,
        }
        # The existing grid becomes the first tab so nothing is orphaned: a
        # naive "ROOT owns only TABS" rewrite would silently drop every chart
        # under GRID_ID.
        grid_id = None
        if ROOT_ID_KEY in layout:
            for child in layout[ROOT_ID_KEY].get("children") or []:
                if _widgets(layout).get(child, {}).get("type") == GRID:
                    grid_id = child
                    break
        if grid_id is not None:
            first_tab = _new_tab_id(layout)
            # A GRID cannot be a child of a TAB, so the grid's own children are
            # re-parented onto the new tab and the grid itself is removed.
            # Referencing the grid and then deleting it would orphan every row
            # and chart that used to live on the dashboard.
            grid_children = list(_widgets(layout).get(grid_id, {}).get("children") or [])
            layout[first_tab] = {
                "children": grid_children,
                "id": first_tab,
                "meta": {"text": args_free_name(layout, "Principal")},
                "type": TAB,
            }
            layout[tabs_id]["children"] = [first_tab]
            layout.pop(grid_id, None)
    # ROOT owns exactly one child: the tabs container.
    if ROOT_ID_KEY in layout:
        layout[ROOT_ID_KEY]["children"] = [tabs_id]
    layout.pop(GRID_ID_KEY, None)
    return tabs_id


def args_free_name(layout: dict, base: str) -> str:
    """A tab display name that does not collide with an existing one."""
    taken = {name for _, name in _all_tabs(layout) if name}
    if base not in taken:
        return base
    n = 2
    while f"{base} {n}" in taken:
        n += 1
    return f"{base} {n}"


def _ensure_grid(layout: dict) -> str:
    """Return a GRID component id under ROOT, creating one when absent.

    Invariant enforced here: ROOT has exactly one child, and it is a GRID or a
    TABS (superset-frontend `isValidChild` allows only those two under ROOT, and
    the builder picks `ROOT.children[0]` to decide whether the dashboard is
    tabbed). So a dashboard is either tabbed or gridded, never both at top level.

    When the dashboard is already tabbed, the grid is *rejected* rather than
    silently added next to the tabs: doing so would either hide the tabs or make
    the layout invalid. Use `--tab` to place a chart on a tabbed dashboard.
    """
    widgets = _widgets(layout)
    root = widgets.get(ROOT_ID_KEY)
    if root is None:
        raise SupersetError("dashboard layout has no ROOT_ID; refusing to rewrite it")
    children = [c for c in root.get("children") or [] if c in widgets]
    for child in children:
        if widgets.get(child, {}).get("type") == GRID:
            return child
    if children:
        # a non-grid top-level container (TABS) already exists
        raise SupersetError(
            "this dashboard is tabbed, so a top-level grid cannot be added: ROOT "
            "may hold exactly one child, either a GRID or a TABS. Place the chart "
            "on a tab with --tab instead."
        )
    layout[GRID_ID_KEY] = {"children": [], "id": GRID_ID_KEY, "meta": {}, "type": GRID}
    root["children"] = [GRID_ID_KEY]
    return GRID_ID_KEY


def _new_tab_id(layout: dict) -> str:
    existing = {k for k in _widgets(layout) if k.startswith("TAB-")}
    n = len(existing) + 1
    while f"TAB-{n}" in existing:
        n += 1
    return f"TAB-{n}"


def _new_row_id(layout: dict) -> str:
    existing = {k for k in _widgets(layout) if k.startswith("ROW-")}
    n = len(existing) + 1
    while f"ROW-{n}" in existing:
        n += 1
    return f"ROW-{n}"


def _new_column_id(layout: dict) -> str:
    existing = {k for k in _widgets(layout) if k.startswith("COLUMN-")}
    n = len(existing) + 1
    while f"COLUMN-{n}" in existing:
        n += 1
    return f"COLUMN-{n}"


def _attach_chart(layout: dict, parent_id: str, chart_id: int, chart_key: str | None = None) -> None:
    """Place a chart component under `parent_id`.

    When `chart_key` is given the EXISTING component is reused, so its id, size
    and any other meta survive the move. Creating a new component instead would
    silently reset width/height and could orphan the old component.
    """
    row_id = _new_row_id(layout)
    column_id = _new_column_id(layout)
    chart_key = chart_key or f"CHART-{chart_id}"
    if chart_key not in layout:
        layout[chart_key] = {
            "children": [],
            "id": chart_key,
            "meta": {"chartId": chart_id, "height": 50, "width": 6},
            "type": CHART,
        }
    layout[column_id] = {
        "children": [chart_key],
        "id": column_id,
        "meta": {"background": "BACKGROUND_TRANSPARENT", "width": 6},
        "type": COLUMN,
    }
    layout[row_id] = {
        "children": [column_id],
        "id": row_id,
        "meta": {"background": "BACKGROUND_TRANSPARENT"},
        "type": ROW,
    }
    layout[parent_id]["children"] = list(layout[parent_id].get("children") or []) + [row_id]


def _metadata_of(result: dict) -> dict:
    """Parse a dashboard GET result's json_metadata string into a dict.

    Raises rather than returning {} on malformed input: a layout write carries
    this metadata forward, so silently substituting an empty dict would reset the
    dashboard's filters, colours and expanded slices.
    """
    raw = result.get("json_metadata")
    if not raw:
        return {}
    if isinstance(raw, dict):
        return dict(raw)
    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, TypeError) as exc:
        raise SupersetError(
            f"dashboard json_metadata is not valid JSON ({exc}); refusing to rewrite "
            "the layout so existing configuration is not reset. Fix the dashboard's "
            "metadata in the Superset UI first."
        ) from exc
    if not isinstance(parsed, dict):
        raise SupersetError(
            "dashboard json_metadata is not a JSON object; refusing to rewrite the "
            "layout so existing configuration is not reset."
        )
    return parsed


def _metadata_payload(existing_metadata: dict, layout: dict) -> dict:
    """Build the json_metadata payload for a layout write.

    `DashboardDAO.set_dash_metadata` (superset/daos/dashboard.py:246) starts from
    the dashboard's existing json_metadata and then **overwrites a fixed list of
    keys with defaults taken from the payload** — color_scheme, expanded_slices,
    refresh_frequency, label_colors, shared_label_colors, map_label_colors,
    color_scheme_domain, cross_filters_enabled — and pops filter_scopes and
    default_filters when the payload omits them. Sending `positions` alone would
    therefore silently reset those keys and destroy cross-filter configuration.

    So the payload carries the dashboard's *current* metadata, with `positions`
    added and the layout-derived members removed (set_dash_metadata rewrites
    position_json from `positions` and pops `positions` from metadata itself).
    """
    payload = dict(existing_metadata)
    payload.pop("positions", None)
    payload["positions"] = _positions_from_layout(layout)
    return payload


def _apply_layout(client: Client, dashboard_id: int, layout: dict, what: str,
                  existing_metadata: dict | None = None) -> dict:
    """Write the layout through json_metadata.positions so slices stay in sync.

    DashboardDAO.set_dash_metadata rebuilds dashboard.slices from the chartIds in
    `positions` and rewrites position_json from the same data, in one transaction.
    position_json is included as a JSON *string*, which is what the REST schema
    declares; it is what a client would see on a subsequent GET.
    """
    layout = _rebuild_parents(layout)
    expected = _chart_ids(layout)
    payload = {
        "json_metadata": json.dumps(_metadata_payload(existing_metadata or {}, layout)),
        "position_json": json.dumps(layout),
    }
    client.put("dashboard", dashboard_id, payload)
    _verify(client, dashboard_id, expected, what)
    return {"dashboard_id": dashboard_id, "what": what}


def _verify(client: Client, dashboard_id: int, expected: set[int], what: str) -> None:
    """Re-read the dashboard and confirm the write actually took effect.

    Three things must hold, or the dashboard may be inconsistent and the caller
    must not retry blindly:
      * every chart we intended is reachable in the stored layout;
      * no child reference points at a missing component;
      * the layout still carries its version marker.
    Chart membership in `dashboard.slices` is checked by Superset's command layer
    (it raises on an inaccessible chart); the stored layout is what we can verify.
    """
    after = client.get("dashboard", dashboard_id)
    layout = _load_layout(after)
    if _chart_ids(layout) != expected:
        raise SupersetError(
            f"{what} applied but reachable charts did not match (expected "
            f"{sorted(expected)}, got {sorted(_chart_ids(layout))}); the dashboard "
            "may be inconsistent - inspect it in the Superset UI before retrying"
        )
    dangling = _dangling(layout)
    if dangling:
        raise SupersetError(
            f"{what} left dangling component references {dangling}; the dashboard "
            "may be inconsistent - inspect it in the Superset UI before retrying"
        )


def _chart_ids(layout: dict) -> set[int]:
    return set(_charts(layout))


# ---- commands -------------------------------------------------------------


def cmd_show(client: Client, args: argparse.Namespace) -> int:
    result = client.get(args.kind, args.id)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


def cmd_rename_dashboard(client: Client, args: argparse.Namespace) -> int:
    result = client.get("dashboard", args.id)
    _report_ownership("dashboard", args.id, result)
    if args.description is not None:
        # DashboardPutSchema (superset/dashboards/schemas.py) has no `description`
        # field: dashboard titles, slugs, layout, css, theme and metadata are
        # updatable, but the description column is not exposed on the REST update
        # path in 6.1.0. Sending it would fail schema validation with a 400.
        raise SupersetError(
            "a dashboard description cannot be set over the 6.1.0 REST API: "
            "DashboardPutSchema exposes no `description` field. Set it in the "
            "Superset UI (dashboard -> Edit -> Properties) or by an Admin."
        )
    payload: dict = {}
    if args.title is not None:
        payload["dashboard_title"] = args.title
    if args.slug is not None:
        payload["slug"] = args.slug
    out = client.put("dashboard", args.id, payload)
    _confirm(f"dashboard {args.id} updated", out)
    return 0


def cmd_rename_dataset(client: Client, args: argparse.Namespace) -> int:
    result = client.get("dataset", args.id)
    _report_ownership("dataset", args.id, result)
    payload: dict = {}
    if args.name is not None:
        payload["table_name"] = args.name
    if args.description is not None:
        payload["description"] = args.description
    out = client.put("dataset", args.id, payload)
    _confirm(f"dataset {args.id} updated", out)
    return 0


def cmd_rename_chart(client: Client, args: argparse.Namespace) -> int:
    result = client.get("chart", args.id)
    _report_ownership("chart", args.id, result)
    payload: dict = {}
    if args.name is not None:
        payload["slice_name"] = args.name
    if args.description is not None:
        payload["description"] = args.description
    out = client.put("chart", args.id, payload)
    _confirm(f"chart {args.id} updated", out)
    return 0


def cmd_set_filters(client: Client, args: argparse.Namespace) -> int:
    """Replace the dashboard's native filters.

    There is no "set the whole array" REST verb in 6.1.0. The dedicated endpoint
    `PUT /api/v1/dashboard/<pk>/filters` takes a *diff* — `deleted`, `modified`
    and `reordered` (`DashboardNativeFiltersConfigUpdateSchema`), and
    `DashboardDAO.update_native_filters_config` applies it:
      * an id in `deleted` is removed;
      * an object in `modified` replaces the matching id, or is appended when the
        id is not already present;
      * `reordered` sets the final order, and is ignored when empty.
    So a full replacement is "delete every existing id, then send the new list as
    modified".
    """
    result = client.get("dashboard", args.id)
    _report_ownership("dashboard", args.id, result)
    file_path = args.file_opt or args.file
    try:
        with open(file_path, encoding="utf-8") as handle:
            filters = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise SupersetError(f"cannot read filters file {file_path}: {exc}") from exc
    if not isinstance(filters, list):
        raise SupersetError("filters file must contain a JSON array of native filter objects")
    for item in filters:
        if not isinstance(item, dict) or not item.get("id"):
            raise SupersetError("every native filter must be an object with a non-empty `id`")

    existing = (_metadata_of(result).get("native_filter_configuration") or [])
    existing_ids = [
        str(f.get("id")) for f in existing if isinstance(f, dict) and f.get("id") is not None
    ]
    body = {
        "deleted": existing_ids,
        "modified": filters,
        "reordered": [str(f["id"]) for f in filters],
    }
    out = client.put_filters(args.id, body)
    _confirm(
        f"dashboard {args.id} native filters replaced "
        f"({len(existing_ids)} removed, {len(filters)} in place)",
        out,
    )
    return 0


def cmd_create_tab(client: Client, args: argparse.Namespace) -> int:
    result = client.get("dashboard", args.id)
    _report_ownership("dashboard", args.id, result)
    layout = _load_layout(result)
    existing = _find_tab(layout, args.name)
    if existing:
        raise SupersetError(f"dashboard {args.id} already has a tab named '{args.name}' (id {existing})")
    tabs_id = _ensure_tabs(layout)
    tab_id = _new_tab_id(layout)
    layout[tab_id] = {
        "children": [],
        "id": tab_id,
        "meta": {"text": args.name},
        "type": TAB,
    }
    layout[tabs_id]["children"] = list(layout[tabs_id].get("children") or []) + [tab_id]
    for chart_id in args.charts:
        if chart_id in _charts(layout):
            raise SupersetError(f"chart {chart_id} is already on this dashboard")
        # A chart must exist to be placed on the dashboard. The dashboard write
        # only records the chartId, so an unknown id would create a dangling
        # CHART component that fails when the dashboard is opened.
        chart = client.get("chart", chart_id)
        _report_ownership("chart", chart_id, chart)
        _attach_chart(layout, tab_id, chart_id)
    _apply_layout(client, args.id, layout, f"tab '{args.name}'", _metadata_of(result))
    print(f"OK dashboard {args.id}: tab '{args.name}' created"
          + (f" with charts {args.charts}" if args.charts else ""))
    return 0


def cmd_move_chart(client: Client, args: argparse.Namespace) -> int:
    """Move a chart that is already on the dashboard into a tab (or the grid)."""
    result = client.get("dashboard", args.id)
    _report_ownership("dashboard", args.id, result)
    layout = _load_layout(result)
    chart_key = _charts(layout).get(args.chart_id)
    if chart_key is None:
        raise SupersetError(
            f"chart {args.chart_id} is not on dashboard {args.id}. Use add-chart first, "
            "or generate the dashboard with the chart included."
        )

    # detach from wherever it lives now
    for key, widget in _widgets(layout).items():
        children = widget.get("children") or []
        if chart_key in children:
            layout[key]["children"] = [c for c in children if c != chart_key]
    _drop_empty_containers(layout)

    if args.tab is None:
        # "top level" means the grid: a TABS container only accepts TAB children,
        # so a chart must never be attached directly to TABS.
        target = _ensure_grid(layout)
    else:
        target = _find_tab(layout, args.tab)
        if target is None:
            raise SupersetError(
                f"tab '{args.tab}' not found on dashboard {args.id}; available: "
                + (", ".join(name or tab_id for tab_id, name in _all_tabs(layout)) or "none")
            )
    _attach_chart(layout, target, args.chart_id, chart_key=chart_key)
    _apply_layout(client, args.id, layout, f"chart {args.chart_id} move", _metadata_of(result))
    print(f"OK dashboard {args.id}: chart {args.chart_id} placed in "
          f"'{args.tab or 'the top-level grid'}'")
    return 0


def _drop_empty_containers(layout: dict) -> None:
    """Prune emptied ROW/COLUMN containers AND the child refs pointing at them.

    Superset indexes `children` ids directly (superset/models/dashboard.py tabs
    handling), so a surviving parent that still lists a deleted component is a
    dangling reference: it breaks later reads and dashboard updates.

    The top-level TABS/TAB structure is preserved when the dashboard is tabbed:
    pruning the last tab out from under a tabbed dashboard leaves ROOT with no
    valid child, which the frontend cannot render. An empty tab is acceptable.
    """
    tabbed = bool(_widgets(layout).get(ROOT_ID_KEY, {}).get("children")) and any(
        _widgets(layout).get(child, {}).get("type") == TABS
        for child in (_widgets(layout).get(ROOT_ID_KEY, {}).get("children") or [])
    )
    for _ in range(8):
        changed = False
        for key, widget in _widgets(layout).items():
            children = widget.get("children") or []
            kept = [c for c in children if c in layout]
            if len(kept) != len(children):
                layout[key]["children"] = kept
                changed = True
        prunable = {ROW, COLUMN} if tabbed else {ROW, COLUMN, TAB, TABS}
        for key, widget in list(_widgets(layout).items()):
            if widget.get("type") in prunable and not _children_of(layout, key):
                layout.pop(key, None)
                changed = True
        if not changed:
            break


def _dangling(layout: dict) -> list[str]:
    """Child ids that point at a component that does not exist (must be empty)."""
    return [
        child
        for widget in _widgets(layout).values()
        for child in (widget.get("children") or [])
        if child not in layout
    ]


def cmd_add_chart(client: Client, args: argparse.Namespace) -> int:
    """Add a chart to an existing dashboard, into a tab when given."""
    result = client.get("dashboard", args.id)
    _report_ownership("dashboard", args.id, result)
    chart = client.get("chart", args.chart_id)
    _report_ownership("chart", args.chart_id, chart)
    layout = _load_layout(result)
    if args.chart_id in _charts(layout):
        raise SupersetError(f"chart {args.chart_id} is already on dashboard {args.id}")
    if args.tab is None:
        # Never attach a ROW to a TABS container: TABS accepts only TAB children
        # (superset-frontend isValidChild). Without --tab the chart goes to the grid.
        target = _ensure_grid(layout)
    else:
        target = _find_tab(layout, args.tab)
        if target is None:
            raise SupersetError(
                f"tab '{args.tab}' not found on dashboard {args.id}; available: "
                + (", ".join(n or i for i, n in _all_tabs(layout)) or "none")
            )
    _attach_chart(layout, target, args.chart_id)
    _apply_layout(client, args.id, layout, f"chart {args.chart_id} added", _metadata_of(result))
    print(f"OK dashboard {args.id}: chart {args.chart_id} added"
          + (f" to tab '{args.tab}'" if args.tab else ""))
    return 0


def cmd_remove_chart(client: Client, args: argparse.Namespace) -> int:
    """Detach a chart from a dashboard without deleting the chart."""
    result = client.get("dashboard", args.id)
    _report_ownership("dashboard", args.id, result)
    layout = _load_layout(result)
    chart_key = _charts(layout).get(args.chart_id)
    if chart_key is None:
        raise SupersetError(f"chart {args.chart_id} is not on dashboard {args.id}")
    _drop_component(layout, chart_key)
    for key, widget in _widgets(layout).items():
        children = widget.get("children") or []
        if chart_key in children:
            layout[key]["children"] = [c for c in children if c != chart_key]
    _drop_empty_containers(layout)
    # positions rebuilds dashboard.slices, so the chart is genuinely detached
    _apply_layout(client, args.id, layout, f"chart {args.chart_id} removed", _metadata_of(result))
    print(f"OK dashboard {args.id}: chart {args.chart_id} detached (the chart itself is kept)")
    return 0


def cmd_delete_chart(client: Client, args: argparse.Namespace) -> int:
    result = client.get("chart", args.id)
    _report_ownership("chart", args.id, result)
    out = client.delete("chart", args.id)
    _confirm(f"chart {args.id} deleted (permanent in 6.1.0: no trash)", out)
    return 0


def cmd_delete_dashboard(client: Client, args: argparse.Namespace) -> int:
    result = client.get("dashboard", args.id)
    _report_ownership("dashboard", args.id, result)
    out = client.delete("dashboard", args.id)
    # 6.1.0 has no SOFT_DELETE: this removes the dashboard permanently. The
    # charts on it are NOT deleted and remain available.
    _confirm(f"dashboard {args.id} deleted (PERMANENT in 6.1.0: no trash; its charts are kept)", out)
    return 0


def cmd_delete_dataset(client: Client, args: argparse.Namespace) -> int:
    """Delete an owned dataset, after checking that nothing depends on it.

    Superset 6.1.0's DeleteDatasetCommand validates existence and ownership only
    (`commands/dataset/delete.py`), so an owned dataset still referenced by a
    chart — possibly another user's — can be removed, breaking that chart. The
    related-objects endpoint reports dependants, so refuse instead.
    """
    result = client.get("dataset", args.id)
    _report_ownership("dataset", args.id, result)
    status, body = client._request("GET", f"/api/v1/dataset/{args.id}/related_objects")
    if 200 <= status < 300 and isinstance(body, dict):
        related = body.get("result", body) or {}
        charts = related.get("charts") if isinstance(related, dict) else None
        dashboards = related.get("dashboards") if isinstance(related, dict) else None
        if charts:
            names = [c.get("slice_name", c.get("id")) for c in charts if isinstance(c, dict)]
            raise SupersetError(
                f"dataset {args.id} is used by {len(charts)} chart(s): "
                f"{', '.join(str(n) for n in names[:10])}. Deleting it would break "
                "them. Remove those charts from the dataset first, or ask an Admin."
            )
        if dashboards:
            raise SupersetError(
                f"dataset {args.id} backs {len(dashboards)} dashboard(s); deleting it "
                "would empty them. Remove those dashboards' charts first, or ask an Admin."
            )
    out = client.delete("dataset", args.id)
    _confirm(f"dataset {args.id} deleted (permanent in 6.1.0: no trash)", out)
    return 0


def _confirm(message: str, out: dict) -> None:
    print(f"OK {message}: {json.dumps(out)[:200]}")


# ---- cli ------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--url", help="Superset base URL (or SUPERSET_URL env)")
    parser.add_argument("--username", help="agent account (or SUPERSET_USERNAME env)")
    sub = parser.add_subparsers(dest="command", required=True)

    def add(name: str, help_text: str, *, fields=()):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("id", type=int)
        for field in fields:
            p.add_argument(f"--{field.replace('_', '-')}")
        p.set_defaults(body_fields=fields)
        return p

    p = add("rename-dashboard", "rename a dashboard / set its description or slug",
            fields=("title", "description", "slug"))
    p.set_defaults(func=cmd_rename_dashboard)

    p = add("rename-dataset", "rename a dataset / set its description",
            fields=("name", "description"))
    p.set_defaults(func=cmd_rename_dataset)

    p = add("rename-chart", "rename a chart / set its description",
            fields=("name", "description"))
    p.set_defaults(func=cmd_rename_chart)

    p = add("set-filters", "replace a dashboard's native filters from a JSON array file",
            fields=())
    p.add_argument("file", help='path to a JSON array (or pass it with --file)')
    p.add_argument("--file", dest="file_opt", help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_set_filters)

    p = sub.add_parser("create-tab", help="create a tab, optionally seeding it with charts")
    p.add_argument("id", type=int)
    p.add_argument("--name", required=True)
    p.add_argument("--charts", type=int, nargs="*", default=[])
    p.set_defaults(func=cmd_create_tab)

    p = sub.add_parser("move-chart", help="move a chart that is already on the dashboard into a tab")
    p.add_argument("id", type=int)
    p.add_argument("chart_id", type=int)
    p.add_argument("--tab", help="tab name or id; omit for the top level")
    p.set_defaults(func=cmd_move_chart)

    p = sub.add_parser("add-chart", help="add an owned chart to a dashboard, into a tab when given")
    p.add_argument("id", type=int)
    p.add_argument("chart_id", type=int)
    p.add_argument("--tab", help="tab name or id; omit for the top level")
    p.set_defaults(func=cmd_add_chart)

    p = sub.add_parser("remove-chart", help="detach a chart from a dashboard without deleting it")
    p.add_argument("id", type=int)
    p.add_argument("chart_id", type=int)
    p.set_defaults(func=cmd_remove_chart)

    for name, help_text, func in (
        ("delete-chart", "delete an owned chart (PERMANENT in 6.1.0)", cmd_delete_chart),
        ("delete-dashboard", "delete an owned dashboard (charts are kept)", cmd_delete_dashboard),
        ("delete-dataset", "delete an owned dataset (PERMANENT in 6.1.0)", cmd_delete_dataset),
    ):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("id", type=int)
        p.set_defaults(func=func)

    p = sub.add_parser("show", help="print raw JSON for an object (owners, layout, filters)")
    p.add_argument("kind", choices=["dashboard", "dataset", "chart"])
    p.add_argument("id", type=int)
    p.set_defaults(func=cmd_show)

    return parser


def main() -> int:
    args = _build_parser().parse_args()

    body_fields = getattr(args, "body_fields", ())
    values = [getattr(args, f, None) for f in body_fields]
    if body_fields and all(v is None for v in values):
        print("error: nothing to change: pass "
              + " or ".join(f"--{f.replace('_', '-')}" for f in body_fields), file=sys.stderr)
        return 1

    base = args.url or os.environ.get("SUPERSET_URL", "")
    username = args.username or os.environ.get("SUPERSET_USERNAME", "")
    password = os.environ.get("SUPERSET_PASSWORD", "")
    if not base:
        print("error: set --url or SUPERSET_URL", file=sys.stderr)
        return 1
    if not username or not password:
        print("error: set --username/SUPERSET_USERNAME and SUPERSET_PASSWORD", file=sys.stderr)
        return 1

    client = Client(base, username, password)
    try:
        client.login()
        return args.func(client, args)
    except SupersetError as exc:
        _log(f"error: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
