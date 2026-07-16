# Sibling to ../mcp-stdio-bridge/Dockerfile: wraps a stdio-only MCP server
# that ships as a PyPI package (run via `uv`'s `uvx`), instead of an npm
# package (run via `npx`), behind mcp-proxy's stdio->SSE bridge — same
# reachable-over-HTTP/SSE-behind-the-VPN goal, different package ecosystem.
#
# Kept as a separate file rather than folded into ../mcp-stdio-bridge/Dockerfile
# as a dual npm-or-uvx image: that Dockerfile is shared by mcp-filesystem
# (npm-based, works correctly today) and contorting it to branch on ecosystem
# at build time would risk breaking a working service to accommodate one that
# wasn't. mcp-git is the first (and, for now, only) consumer of this file.
#
# Parameterized via build args, mirroring ../mcp-stdio-bridge/Dockerfile.
# Every build-time input is pinned, sourced from configs/versions.env (the
# repo's single source of truth for versions) -- PYTHON_BASE_IMAGE,
# MCP_PROXY_VERSION, UV_VERSION, and MCP_SERVER_VERSION.
#
# VERIFIED this session by an actual `docker build` + `docker run` of this
# Dockerfile on an isolated VPS clone (no production containers touched):
# installed mcp-proxy 0.12.0 does NOT accept a `--sse-path` flag (`mcp-proxy
# --help` confirms it -- the flag mcp-stdio-bridge/Dockerfile's sibling
# invocation passes doesn't exist in this version and makes mcp-proxy exit
# on an argparse error before it ever starts). mcp-proxy 0.12.0 serves SSE at
# /sse by default with no flag needed -- confirmed via its own startup log
# ("Serving MCP Servers via SSE: http://127.0.0.1:8000/sse"). This
# Dockerfile's ENTRYPOINT omits the flag accordingly. The sibling
# ../mcp-stdio-bridge/Dockerfile still passes it (same likely-broken
# argument, on the same mcp-proxy version) -- that's mcp-filesystem's file,
# not touched by this fix; flagged for its own follow-up in SECURITY.md.

ARG PYTHON_BASE_IMAGE=python:3.12-slim
FROM ${PYTHON_BASE_IMAGE}

ARG MCP_PROXY_VERSION
ARG UV_VERSION
# `git` itself (the binary, not the MCP package) is a runtime dependency of
# mcp-server-git -- it shells out to the local git executable to operate on
# the bind-mounted repository, the same way mcp-filesystem's Dockerfile
# installs nodejs/npm as a runtime dependency of npx.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir "mcp-proxy==${MCP_PROXY_VERSION}" "uv==${UV_VERSION}"

ARG MCP_SERVER_PACKAGE
ARG MCP_SERVER_VERSION
ENV MCP_SERVER_PACKAGE=${MCP_SERVER_PACKAGE}
ENV MCP_SERVER_VERSION=${MCP_SERVER_VERSION}

# Runs as a non-root user — same rationale as ../mcp-stdio-bridge/Dockerfile:
# the stdio MCP server this wraps only ever needs read/write access to a
# bind-mounted directory (see docker-compose.yml's mcp-git volumes), never
# root on the container.
RUN useradd --create-home --uid 10001 mcpbridge
USER mcpbridge

EXPOSE 8000

# MCP_SERVER_VERSION is optional, mirroring ../mcp-stdio-bridge/Dockerfile:
# when set, uvx resolves the exact pinned release ("pkg@version"), via uv's
# documented `command@<version>` pin syntax; when blank, uvx falls back to
# its own latest-on-PyPI resolution.
ENTRYPOINT ["sh", "-c", "pkg=\"$MCP_SERVER_PACKAGE\"; if [ -n \"$MCP_SERVER_VERSION\" ]; then pkg=\"$MCP_SERVER_PACKAGE@$MCP_SERVER_VERSION\"; fi; exec mcp-proxy --port 8000 -- uvx \"$pkg\" \"$@\"", "--"]
