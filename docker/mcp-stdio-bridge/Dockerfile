# Generic sidecar: wraps a stdio-only MCP server published as an npm
# package (like the official reference filesystem server) behind
# mcp-proxy's stdio->SSE bridge, so it's reachable over HTTP/SSE from
# behind the VPN instead of only via a local subprocess pipe.
#
# npm/npx-specific by design. mcp-git uses the sibling
# ../mcp-stdio-bridge-python/Dockerfile instead (its reference server ships
# on PyPI, run via uvx, not npm) -- this Dockerfile is not contorted into a
# dual npm-or-uvx image to keep the working npm path (mcp-filesystem)
# untouched. Every build-time input here is pinned, sourced from
# configs/versions.env (the repo's single source of truth for versions) --
# PYTHON_BASE_IMAGE, MCP_PROXY_VERSION, and MCP_SERVER_VERSION. Previously a
# `MCP_PROXY_IMAGE` build-arg was passed by docker-compose.yml but never
# declared or used here, so nothing was actually pinned despite the name;
# that dead arg is gone, replaced by the three below.
#
# VERIFIED this session (Task 5) via `mcp-proxy --help` on the actual pinned
# 0.12.0 release: there is no `--sse-path` flag at all (SSE server options
# are just --port/--host/--stateless/--sse-port(deprecated)/--sse-host
# (deprecated)/--allow-origin/--expose-header). mcp-proxy 0.12.0 always
# serves SSE at /sse -- confirmed both by the absence of the flag and by
# ../mcp-stdio-bridge-python/Dockerfile's own startup-log verification
# ("Serving MCP Servers via SSE: http://127.0.0.1:8000/sse") from Task 4.
# The `--sse-path /sse` this Dockerfile previously passed made mcp-proxy
# exit on an argparse error before ever starting -- mcp-filesystem (the one
# service using this file) was crash-looping in production because of it.
# Fixed by dropping the flag; the default /sse path already matches what
# docker-compose.yml's healthcheck and the mcp-gateway Caddyfile expect.
#
# Also added `--host 0.0.0.0`: mcp-proxy's default --host is 127.0.0.1,
# which only accepts connections from inside this container's own network
# namespace. configs/mcp-gateway/Caddyfile reverse-proxies to this service
# by container DNS name (mcp-filesystem:8000) from the separate mcp-gateway
# container -- loopback-only binding would make it unreachable there even
# though this container's own healthcheck (which also hits 127.0.0.1) would
# still report healthy. Both containers stay on forgeops_internal, which has
# no route to the host's public interface, so this isn't a new exposure.

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
# mcp-filesystem volumes), never root on the container.
RUN useradd --create-home --uid 10001 mcpbridge
USER mcpbridge

EXPOSE 8000

# MCP_SERVER_VERSION is optional: when set, npx resolves the exact pinned
# release ("pkg@version"); when blank, npx falls back to its own
# floating-latest resolution -- the same behavior every service had before
# this pinning fix, not a new failure mode. (mcp-git no longer uses this
# Dockerfile; see ../mcp-stdio-bridge-python/Dockerfile for its uvx-based
# equivalent.)
ENTRYPOINT ["sh", "-c", "pkg=\"$MCP_SERVER_PACKAGE\"; if [ -n \"$MCP_SERVER_VERSION\" ]; then pkg=\"$MCP_SERVER_PACKAGE@$MCP_SERVER_VERSION\"; fi; exec mcp-proxy --port 8000 --host 0.0.0.0 -- npx -y \"$pkg\" \"$@\"", "--"]
