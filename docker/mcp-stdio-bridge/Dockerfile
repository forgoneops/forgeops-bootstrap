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
#
# TASK 7: `npx -y "$pkg"` at container start always attempts a registry
# resolution first -- even with a pinned "pkg@version" -- before it will run
# anything, npx-cached or not. forgeops_internal is `internal: true` (zero
# egress, by design -- shared with production Postgres/Redis; relaxing that
# isolation is not on the table). So this service could never reach a
# stable healthy state as previously built: Task 5's fixes got it past its
# earlier crash points into a new, terminal DNS-resolution failure at this
# exact npx call, confirmed via a real `docker compose up` cycle. Fixed by
# moving the package fetch to `docker build` time (this stage runs on the
# host, which has normal egress) via `npm install -g`, and changing the
# ENTRYPOINT to invoke the already-installed bin directly -- no npx, no
# runtime registry resolution, no network access needed from inside
# forgeops_internal ever again.

ARG PYTHON_BASE_IMAGE=python:3.12-slim@sha256:57cd7c3a7a273101a6485ba99423ee568157882804b1124b4dd04266317710de
FROM ${PYTHON_BASE_IMAGE}

# nodejs/npm/ca-certificates are NOT individually version-pinned -- they
# resolve to whatever's current in PYTHON_BASE_IMAGE's apt snapshot at
# build time (that image is itself pinned by digest above). See
# configs/versions.env's note on this file for why exact apt-package
# pinning isn't done here.
ARG MCP_PROXY_VERSION
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends nodejs npm ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir "mcp-proxy==${MCP_PROXY_VERSION}"

ARG MCP_SERVER_PACKAGE
ARG MCP_SERVER_VERSION
ARG MCP_SERVER_BIN
ENV MCP_SERVER_BIN=${MCP_SERVER_BIN}

# Installs the pinned MCP server package at BUILD time, not container-start
# time (see the TASK 7 note above). Runs as root (before USER mcpbridge
# below) so the package lands in npm's default global prefix for this
# apt-installed nodejs/npm (/usr, on Debian) -- already on every user's
# PATH, no extra ENV plumbing needed. MCP_SERVER_VERSION is REQUIRED
# (build fails otherwise, see the explicit check below) -- there is no
# fallback to an unversioned/latest npm resolution anymore: an accidentally
# blank configs/versions.env entry used to silently mean "whatever npm
# resolves as latest today," baked into the image with no record of what
# version that actually was.
RUN set -e; \
    if [ -z "$MCP_SERVER_VERSION" ]; then \
      echo "MCP_SERVER_VERSION build-arg is required (see configs/versions.env) — refusing to install an unpinned/latest package" >&2; \
      exit 1; \
    fi; \
    npm install -g "$MCP_SERVER_PACKAGE@$MCP_SERVER_VERSION"

# Runs as a non-root user — the stdio MCP server this wraps only ever needs
# read/write access to a bind-mounted directory (see docker-compose.yml's
# mcp-filesystem volumes), never root on the container.
RUN useradd --create-home --uid 10001 mcpbridge
USER mcpbridge

EXPOSE 8000

# MCP_SERVER_BIN names the console binary the installed npm package exposes
# -- not always the same string as the package name (e.g. the scoped
# package "@modelcontextprotocol/server-filesystem" installs the bin
# "mcp-server-filesystem"). Set per-service via docker-compose.yml build
# args. Invoked directly against the build-time-installed package: no npx,
# no runtime registry resolution. (mcp-git no longer uses this Dockerfile;
# see ../mcp-stdio-bridge-python/Dockerfile for its uv-tool-install-based
# equivalent.)
ENTRYPOINT ["sh", "-c", "exec mcp-proxy --port 8000 --host 0.0.0.0 -- \"$MCP_SERVER_BIN\" \"$@\"", "--"]
