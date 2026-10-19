---
name: xerj
description: Definition-first code search over locally indexed repos (xerj search / xerj def)
---
<!-- xerj-init-version: 1 sha256:2431e2257fd251e5 -->

Use XERJ instead of grep when you need code you cannot see in the open files:

- `xerj def "<symbol>"` — where is this defined? Returns file:line + signature in one call.
- `xerj search "<plain words>"` — ranked passages, definitions first; cite the printed file:line.
- `xerj autoindex <folder>` — index a repo first (once; re-index is incremental).
- MCP: the `xerj_search` tool accepts a plain string query and returns the same passages.

Trust the passage over memory: it is the actual code at that path.
