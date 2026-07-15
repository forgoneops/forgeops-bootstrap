# Generic sidecar: wraps a stdio-only MCP server (published as an npm
# package, like the official reference filesystem/git servers) behind
# mcp-proxy's stdio->SSE bridge, so it's reachable over HTTP/SSE from
# behind the VPN instead of only via a local subprocess pipe.
#
# Parameterized via build args so mcp-filesystem and mcp-git in
# docker-compose.yml share this one Dockerfile instead of duplicating it.
#
# NEEDS VERIFICATION before first production deploy: the exact `mcp-proxy`
# CLI invocation below (a trailing `-- <command>` after --port/--sse-path)
# matches the general stdio-proxy convention used across this class of tool,
# but wasn't re-confirmed against `mcp-proxy --help` in the pinned image
# this session — run that once and adjust if the flags differ. Same for the
# `mcp-proxy` PyPI package name (matches the sparfenyuk/mcp-proxy repo name,
# not independently re-checked on pypi.org this session).

FROM python:3.12-slim

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends nodejs npm ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir mcp-proxy

ARG MCP_SERVER_PACKAGE
ENV MCP_SERVER_PACKAGE=${MCP_SERVER_PACKAGE}

# Runs as a non-root user — the stdio MCP server this wraps only ever needs
# read/write access to a bind-mounted directory (see docker-compose.yml's
# mcp-filesystem/mcp-git volumes), never root on the container.
RUN useradd --create-home --uid 10001 mcpbridge
USER mcpbridge

EXPOSE 8000

ENTRYPOINT ["sh", "-c", "exec mcp-proxy --port 8000 --sse-path /sse -- npx -y \"$MCP_SERVER_PACKAGE\" \"$@\"", "--"]
