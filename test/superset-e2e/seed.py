"""Seed the e2e stack: two identities, their roles, data access, an example dataset.

Run inside the superset container:  docker compose exec superset python /tmp/seed.py

The agent role is exactly the permission set documented in
docs/librechat-integrations.md section 1.2. The second identity exists only to
prove the ownership boundary from the other side, so it gets the same grants.

Grants, and why each one:
  object-class permissions      — not enough on their own
  database_access on db.perm    — per-database (NOT all_database_access, which is
                                  a single global pair granting every database)
  datasource_access per dataset — per-dataset (NOT all_datasource_access)
"""
import os

from superset.app import create_app

app = create_app()

AGENT_PASSWORD = os.environ.get("AGENT_PASSWORD", "agent-pw-local-only")
WRITER_PASSWORD = os.environ.get("WRITER_PASSWORD", "writer-pw-local-only")

ROLES = {
    "MCP_DashboardAgent": {
        "user": "librechat-agent",
        "first": "LibreChat",
        "password": AGENT_PASSWORD,
    },
    "MCP_E2EWriter": {
        "user": "e2e-writer",
        "first": "E2E",
        "password": WRITER_PASSWORD,
    },
}

GRANTS = [
    ("can_read", "Dashboard"), ("can_write", "Dashboard"),
    ("can_read", "Chart"), ("can_write", "Chart"),
    ("can_read", "Dataset"), ("can_write", "Dataset"),
    ("can_read", "Database"),
    ("can_read", "SecurityRestApi"),   # GET /api/v1/security/csrf_token/
]


def grant(session, role, action, resource, models):
    """Grant `action` on `resource` to `role`, creating rows as needed."""
    Permission, PermissionView, ViewMenu = models
    perm = session.query(Permission).filter_by(name=action).first()
    if perm is None:
        perm = Permission(name=action)
        session.add(perm)
        session.flush()
    view = session.query(ViewMenu).filter_by(name=resource).first()
    if view is None:
        view = ViewMenu(name=resource)
        session.add(view)
        session.flush()
    pvm = session.query(PermissionView).filter_by(
        permission_id=perm.id, view_menu_id=view.id
    ).first()
    if pvm is None:
        pvm = PermissionView(permission_id=perm.id, view_menu_id=view.id)
        session.add(pvm)
        session.flush()
    if pvm not in role.permissions:
        role.permissions.append(pvm)
    return f"{action} on {resource}"


with app.app_context():
    from flask_appbuilder.security.sqla.models import (
        Permission, PermissionView, ViewMenu,
    )
    from superset import db, security_manager
    from superset.models.core import Database

    models = (Permission, PermissionView, ViewMenu)
    session = db.session
    granted: list[str] = []

    # --- admin, so the REST-based dataset setup below can authenticate ------
    admin = security_manager.find_user("admin")
    if admin is None:
        security_manager.add_user(
            "admin", "Admin", "Admin", "admin@example.com",
            security_manager.find_role("Admin"),
            password=os.environ.get("ADMIN_PASSWORD", "admin"),
        )

    # --- the two agent identities ------------------------------------------
    users = {}
    for role_name, spec in ROLES.items():
        role = security_manager.find_role(role_name)
        if role is None:
            role = security_manager.add_role(role_name)
        for action, resource in GRANTS:
            granted.append(grant(session, role, action, resource, models))

        user = security_manager.find_user(spec["user"])
        if user is None:
            user = security_manager.add_user(
                spec["user"], spec["first"], "Agent",
                f"{spec['user']}@example.com", role, password=spec["password"],
            )
        else:
            user.roles = [role]
        users[spec["user"]] = user

    # --- a database and a table for the agent to work with ------------------
    database = session.query(Database).filter_by(database_name="examples").first()
    if database is None:
        database = Database(database_name="examples")
        session.add(database)
        session.flush()

    for role_name in ROLES:
        role = security_manager.find_role(role_name)
        granted.append(grant(session, role, "database_access", database.perm, models))

    # --- the example table (physical, so no virtual-dataset step is needed) --
    from sqlalchemy import text

    session.execute(text(
        "CREATE TABLE IF NOT EXISTS e2e_frota ("
        " id serial primary key,"
        " nome text,"
        " regiao text,"
        " distancia_km numeric"
        ")"
    ))
    session.execute(text(
        "INSERT INTO e2e_frota (nome, regiao, distancia_km) VALUES "
        "('alfa','norte',12.5),('beta','sul',31.0),('gama','norte',7.25),"
        "('delta','leste',44.75),('epsilon','sul',19.5) "
        "ON CONFLICT DO NOTHING"
    ))
    session.flush()

    # --- register the dataset and grant per-dataset access ------------------
    from superset.connectors.sqla.models import SqlaTable

    dataset = (
        session.query(SqlaTable).filter_by(
            database_id=database.id, table_name="e2e_frota"
        ).first()
    )
    if dataset is None:
        dataset = SqlaTable(
            table_name="e2e_frota",
            database_id=database.id,
            schema="public",
            catalog=database.get_default_catalog(),
        )
        session.add(dataset)
        session.flush()

    for role_name in ROLES:
        role = security_manager.find_role(role_name)
        perm_name = f"[examples].[e2e_frota](id:{dataset.id})"
        granted.append(grant(session, role, "datasource_access", perm_name, models))

    session.commit()

    print("granted (deduplicated):")
    for line in sorted(set(granted)):
        print("  -", line)
    print()
    for name in (spec["user"] for spec in ROLES.values()):
        user = security_manager.find_user(name)
        print(f"user {user.username} roles={[r.name for r in user.roles]}")
    print(f"database {database.database_name} perm={database.perm} id={database.id}")
    print(f"dataset e2e_frota id={dataset.id}")
