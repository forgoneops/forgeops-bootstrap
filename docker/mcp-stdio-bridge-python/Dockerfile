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
# ../mcp-stdio-bridge/Dockerfile previously still passed it (same broken
# argument, on the same mcp-proxy version) -- fixed in Task 5 to match this
# file (see that Dockerfile's own comment block for the fix + verification).
#
# Task 5 also added `--host 0.0.0.0` here (mirroring the same fix applied to
# ../mcp-stdio-bridge/Dockerfile): mcp-proxy's default --host is 127.0.0.1,
# loopback-only inside this container's own network namespace, but
# configs/mcp-gateway/Caddyfile reverse-proxies to this service by container
# DNS name (mcp-git:8000) from the separate mcp-gateway container -- that
# path needs a non-loopback bind. Both containers stay on forgeops_internal
# (no route to the host's public interface), so this isn't a new exposure.
#
# TASK 7: `uvx "$pkg"` at container start resolves/installs from PyPI on
# every single start, pinned version or not -- and forgeops_internal is
# `internal: true` (zero egress by design, shared with production
# Postgres/Redis; relaxing that isolation is not on the table). This
# service could therefore never reach a stable healthy state: Task 5's
# fixes got it past its earlier crash points into a terminal
# DNS-resolution failure at this exact uvx call, confirmed via a real
# `docker compose up` cycle. Fixed by resolving and installing the pinned
# package at `docker build` time (this stage runs on the host, which has
# normal egress) via `uv tool install`, into a fixed system directory
# (/opt/uv-tools) rather than $HOME -- deliberately outside the
# tmpfs-mounted home directory below, so the build-time install survives
# into the running container instead of being shadowed by an empty tmpfs
# mount every start. The ENTRYPOINT then invokes the installed console
# script directly: no uvx, no runtime PyPI resolution, no network access
# needed from inside forgeops_internal ever again.

ARG PYTHON_BASE_IMAGE=python:3.12-slim@sha256:57cd7c3a7a273101a6485ba99423ee568157882804b1124b4dd04266317710de
FROM ${PYTHON_BASE_IMAGE}

ARG MCP_PROXY_VERSION
ARG UV_VERSION
# `git` itself (the binary, not the MCP package) is a runtime dependency of
# mcp-server-git -- it shells out to the local git executable to operate on
# the bind-mounted repository, the same way mcp-filesystem's Dockerfile
# installs nodejs/npm as a runtime dependency of npx.
#
# git/ca-certificates are NOT individually version-pinned -- they resolve
# to whatever's current in PYTHON_BASE_IMAGE's apt snapshot at build time
# (that image is itself pinned by digest above). See configs/versions.env's
# note on the sibling Dockerfile for why exact apt-package pinning isn't
# done here.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir "mcp-proxy==${MCP_PROXY_VERSION}" "uv==${UV_VERSION}"

ARG MCP_SERVER_PACKAGE
ARG MCP_SERVER_VERSION
ARG MCP_SERVER_BIN
ENV MCP_SERVER_BIN=${MCP_SERVER_BIN}

# Installs the pinned MCP server package at BUILD time, not container-start
# time (see the TASK 7 note above). Runs as root (before USER mcpbridge
# below), targeting a fixed, non-$HOME directory via UV_TOOL_DIR /
# UV_TOOL_BIN_DIR: mcp-git's home dir is tmpfs-mounted fresh (empty) at
# every container start (see this Dockerfile's docker-compose.yml service
# block -- that tmpfs previously existed because uvx needed to write
# .cache/uv and .local/share/uv/tools there on every start; now that the
# tool is baked in at build time and invoked directly, uvx never runs at
# runtime and that home-dir write no longer happens). Installing under
# $HOME instead would put the freshly-built tool exactly where the
# empty runtime tmpfs mount would immediately hide it again. chmod at the
# end ensures the non-root mcpbridge user (USER below) can execute what
# root just installed.
# MCP_SERVER_VERSION is REQUIRED (build fails otherwise, see the explicit
# check below) -- no fallback to an unversioned/latest PyPI resolution: an
# accidentally blank configs/versions.env entry used to silently mean
# "whatever uv resolves as latest today," baked into the image with no
# record of what version that actually was.
ENV UV_TOOL_DIR=/opt/uv-tools
ENV UV_TOOL_BIN_DIR=/opt/uv-tools/bin
ENV PATH="/opt/uv-tools/bin:${PATH}"
RUN set -e; \
    if [ -z "$MCP_SERVER_VERSION" ]; then \
      echo "MCP_SERVER_VERSION build-arg is required (see configs/versions.env) — refusing to install an unpinned/latest package" >&2; \
      exit 1; \
    fi; \
    uv tool install "$MCP_SERVER_PACKAGE==$MCP_SERVER_VERSION"; \
    chmod -R a+rX /opt/uv-tools

# Runs as a non-root user — same rationale as ../mcp-stdio-bridge/Dockerfile:
# the stdio MCP server this wraps only ever needs read/write access to a
# bind-mounted directory (see docker-compose.yml's mcp-git volumes), never
# root on the container.
RUN useradd --create-home --uid 10001 mcpbridge
USER mcpbridge

EXPOSE 8000

# MCP_SERVER_BIN names the console script the installed PyPI package
# exposes (mirrors ../mcp-stdio-bridge/Dockerfile's MCP_SERVER_BIN for npm
# packages) -- for mcp-server-git this matches the package name exactly
# (upstream pyproject.toml: `[project.scripts] mcp-server-git =
# "mcp_server_git:main"`), but is kept as its own build arg rather than
# reused from MCP_SERVER_PACKAGE since PyPI console-script names aren't
# guaranteed to match the package name in general. Invoked directly via
# PATH (UV_TOOL_BIN_DIR above): no uvx, no runtime PyPI resolution.
ENTRYPOINT ["sh", "-c", "exec mcp-proxy --port 8000 --host 0.0.0.0 -- \"$MCP_SERVER_BIN\" \"$@\"", "--"]
