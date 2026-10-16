# Local e2e image: apache-superset 6.1.0 + fastmcp, for the MCP integration test.
#
# Only two things are added to the base image:
#   1. fastmcp==3.1.0 — the pin the MCP server needs (later 3.x breaks JWT
#      validation; see specs/librechat-superset.md "Install").
#   2. superset_config.py — the MCP block, layering on the image's own config.
ARG BASE_IMAGE=communityfirst/superset-deployment:6.1.0_20260803-1652
FROM ${BASE_IMAGE}

# The image's `python` is a venv without pip, the PATH `pip` targets system
# site-packages the runtime user cannot write to, and --prefix needs a
# root-owned target. So install as root into a dedicated prefix, then hand the
# tree to the runtime user and expose it through PYTHONPATH.
USER root
RUN pip install --no-cache-dir --prefix /opt/mcp-deps "fastmcp==3.1.0" \
 && chmod -R a+rX /opt/mcp-deps \
 && PYTHONPATH=/opt/mcp-deps/lib/python3.10/site-packages \
      python -c "import fastmcp; print('fastmcp', fastmcp.__version__)"
USER superset

ENV PYTHONPATH=/opt/mcp-deps/lib/python3.10/site-packages

# Keep the image's own full config (Postgres/Redis/Celery/OAuth wiring) as the
# base, then lay the MCP settings on top. The image's config is exec'd at runtime
# by superset_config.py, so nothing is duplicated here.
USER root
RUN cp /app/pythonpath/superset_config.py /app/pythonpath/superset_config.base.py \
 && chmod 644 /app/pythonpath/superset_config.py
COPY superset_config.py /app/pythonpath/superset_config.py

# Same chart-ownership patch as the production image (javari-ops/superset-mcp-Dockerfile).
RUN /app/.venv/bin/python -c 'import pathlib;p=pathlib.Path("/app/superset/mcp_service/dashboard/tool/add_chart_to_existing_dashboard.py");s=p.read_text();old="            validation = check_chart_data_access(new_chart)\n";new="            from superset import security_manager as _sm\n            from superset.exceptions import SupersetSecurityException as _SSE\n            try:\n                _sm.raise_for_ownership(new_chart)\n            except _SSE:\n                return AddChartToDashboardResponse(dashboard=None, dashboard_url=None, position=None, error=\"Chart \" + str(request.chart_id) + \" is not owned by the service user\")\n"+old;assert s.count(old)==1,"patch anchor not found";p.write_text(s.replace(old,new,1))' \
 && /app/.venv/bin/python -c "import sys;compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')" /app/superset/mcp_service/dashboard/tool/add_chart_to_existing_dashboard.py
USER superset

ENV SUPERSET_CONFIG_PATH=/app/pythonpath/superset_config.py
EXPOSE 8088 5008
