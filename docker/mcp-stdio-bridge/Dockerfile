# Generic sidecar: wraps a stdio-only MCP server (published as an npm
# package, like the official reference filesystem/git servers) behind
# mcp-proxy's stdio->SSE bridge, so it's reachable over HTTP/SSE from
# behind the VPN instead of only via a local subprocess pipe.
#
# Parameterized via build args so mcp-filesystem and mcp-git in
# docker-compose.yml share this one Dockerfile instead of duplicating it.
# Every build-time input is pinned, sourced from configs/versions.env (the
# repo's single source of truth for versions) -- PYTHON_BASE_IMAGE,
# MCP_PROXY_VERSION, and MCP_SERVER_VERSION. Previously a `MCP_PROXY_IMAGE`
# build-arg was passed by docker-compose.yml but never declared or used
# here, so nothing was actually pinned despite the name; that dead arg is
# gone, replaced by the three below.
#
# NEEDS VERIFICATION before first production deploy: the exact `mcp-proxy`
# CLI invocation below (a trailing `-- <command>` after --port/--sse-path)
# matches the general stdio-proxy convention used across this class of tool,
# but wasn't re-confirmed against `mcp-proxy --help` this session — run that
# once and adjust if the flags differ.
#
# KNOWN BROKEN as of this session: docker-compose.yml's mcp-git service
# passes MCP_SERVER_PACKAGE="@modelcontextprotocol/server-git", but that npm
# package does not exist (confirmed 404 against registry.npmjs.org this
# session). The official git MCP server ships as the PyPI/uvx package
# `mcp-server-git`, not an npm package, so this Dockerfile's npx-based
# bridge can't run it as-is -- mcp-git will crash-loop at container start
# regardless of the MCP_SERVER_VERSION pin below. Not fixed here (needs
# either a renamed/republished npm package upstream, or a second uvx-based
# code path in this Dockerfile); see configs/versions.env's
# MCP_GIT_SERVER_VERSION comment and SECURITY.md's "Known gaps" section.

ARG PYTHON_BASE_IMAGE=python:3.12-slim
FROM ${PYTHON_BASE_IMAGE}

ARG MCP_PROXY_VERSION
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends nodejs npm ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir "mcp-proxy==${MCP_PROXY_VERSION}"

ARG MCP_SERVER_PACKAGE
ARG MCP_SERVER_VERSION
ENV MCP_SERVER_PACKAGE=${MCP_SERVER_PACKAGE}
ENV MCP_SERVER_VERSION=${MCP_SERVER_VERSION}

# Runs as a non-root user — the stdio MCP server this wraps only ever needs
# read/write access to a bind-mounted directory (see docker-compose.yml's
# mcp-filesystem/mcp-git volumes), never root on the container.
RUN useradd --create-home --uid 10001 mcpbridge
USER mcpbridge

EXPOSE 8000

# MCP_SERVER_VERSION is optional: when set, npx resolves the exact pinned
# release ("pkg@version"); when blank (see MCP_GIT_SERVER_VERSION's comment
# in configs/versions.env for why mcp-git currently ships this blank), npx
# falls back to its own floating-latest resolution -- the same behavior
# every service had before this pinning fix, not a new failure mode.
ENTRYPOINT ["sh", "-c", "pkg=\"$MCP_SERVER_PACKAGE\"; if [ -n \"$MCP_SERVER_VERSION\" ]; then pkg=\"$MCP_SERVER_PACKAGE@$MCP_SERVER_VERSION\"; fi; exec mcp-proxy --port 8000 --sse-path /sse -- npx -y \"$pkg\" \"$@\"", "--"]
