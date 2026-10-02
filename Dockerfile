# syntax=docker/dockerfile:1
#
# pi-docker — a self-contained, persistent container for the pi coding agent
# and its web UI (pi-web-ui).
#
#   docker build -t pi-docker .
#   docker run -d --init --name pi-web-ui -p 8787:8787 \
#     -v "$PWD/data:/data" -v "$PWD/workspace:/workspace" pi-docker
#
# Publishing the port and reaching it by IP only works when that IP/hostname is
# acceptable to pi-web-ui's Host guard — set PI_WEB_ALLOW_HOSTS (or leave it
# unset for loopback/LAN) or the request is refused with 403. Behind a reverse
# proxy you do not need `-p` at all. See "Host allow-list" below.
#
# ---------------------------------------------------------------------------
# Why this file exists (vs. installing at first start)
# ---------------------------------------------------------------------------
#
# The original compose installed pi-web-ui on first boot, which meant an empty
# data volume re-downloaded everything (minutes of apt + npm) and an image that
# was a bare `node:*-bookworm-slim` with no toolchain until it happened.
#
# This Dockerfile bakes pi in at build time instead, so the container starts in
# seconds. It is single-stage on purpose: the C/C++ toolchain that node-pty
# needs at install time is *also* what the agent needs later to install native
# tools, so removing it would break half the point of the image.
#
# ---------------------------------------------------------------------------
# Persistence model — everything lives under /data (one volume)
# ---------------------------------------------------------------------------
#
#   /data/home      HOME          -> ~/.pi-web (UI state, plugins, sessions),
#                                     ~/.npm cache, pip --user, ~/.local/bin,
#                                     ~/.cargo, ~/go, ~/.bun — all persisted
#   /data/agent     PI_CODING_AGENT_DIR -> pi config, API keys, sessions,
#                                     packages/extensions, and its own bin/
#   /data/npm       NPM_CONFIG_PREFIX   -> `npm install -g <tool>` from inside
#                                     pi lands here and survives restarts
#   /workspace      PI_WEB_CWD    -> the agent's project files
#
# The app itself (pi-web-ui, pi CLI) is installed into the image's own prefix
# (/usr/local) and that prefix comes FIRST on PATH, ahead of /data/npm: the image
# is the source of truth for pi-web-ui. That matters twice over — PI_WEB_MANAGED=1
# makes the in-app updater refuse by design ("managed from outside"), and an older
# pi-web-ui left in /data/npm by a previous first-start install must not shadow
# the version the image was built with. /data/npm stays on PATH for extra tools.
# ---------------------------------------------------------------------------

# Node 26 is the current LTS line (Node 22, the original base, went to
# maintenance in 2026). 24 is still supported and is one build arg away:
#   docker build --build-arg NODE_VERSION=24 .
# Both are exercised by the CI smoke test, which also proves node-pty still
# compiles from source against the chosen Node (it has no linux prebuild).
ARG NODE_VERSION=26

FROM node:${NODE_VERSION}-bookworm-slim

# Tooling versions — override at build time to pin, e.g.
#   docker build --build-arg PI_WEB_UI_VERSION=0.85.0 .
ARG PI_WEB_UI_VERSION=latest
ARG PI_CODING_AGENT_VERSION=latest

# Build metadata, passed by .github/workflows/*.yml
ARG VERSION=dev
ARG COMMIT=unknown

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

# The C/C++ toolchain is required BEFORE npm touches node-pty (it compiles from
# source on Linux — the published tarball only ships darwin/win32 prebuilds), and
# it is kept in the final image so the agent can rebuild native modules later.
# The rest is the everyday CLI surface a coding agent expects to find.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less procps ripgrep \
      python3 python3-pip python3-venv make g++ \
 && rm -rf /var/lib/apt/lists/*

# Debian marks the system Python as "externally managed" (PEP 668), which makes
# `pip install --user <tool>` refuse outright — and `--user` is precisely the
# persistent path the bundled skill documents. Drop the guard so it works;
# venv and pipx behaviour is unchanged.
RUN rm -f /usr/lib/python3*/EXTERNALLY-MANAGED

# Installed into the image prefix (/usr/local), NOT the persisted /data/npm:
# a fresh, empty data volume must never leave the container without its app.
# The caches speed up rebuilds (and the arm64 leg of a release) only — they are
# not part of the image. node-gyp headers are architecture-independent, so they
# are shared between platforms.
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.cache/node-gyp \
    npm install --global \
      "pi-web-ui@${PI_WEB_UI_VERSION}" \
      "@earendil-works/pi-coding-agent@${PI_CODING_AGENT_VERSION}"

# The persisted layout. Created here so the volume inherits sane ownership even
# when Docker creates it on first run.
RUN mkdir -p /data/home /data/agent /data/npm /workspace

# Runtime environment. HOME and NPM_CONFIG_PREFIX point into the volume, which
# is what makes both the agent's data and any tool it installs survive restarts.
# Every $HOME-relative tool directory worth having is on PATH as well.
ENV HOME=/data/home \
    NPM_CONFIG_PREFIX=/data/npm \
    PI_CODING_AGENT_DIR=/data/agent \
    PI_WEB_DATA_DIR=/data/home/.pi-web \
    PI_WEB_CWD=/workspace \
    PI_WEB_HOST=0.0.0.0 \
    PI_WEB_PORT=8787 \
    PI_WEB_MANAGED=1 \
    NODE_ENV=production \
    PATH=/data/agent/bin:/usr/local/sbin:/usr/local/bin:/data/npm/bin:/data/home/.local/bin:/data/home/.cargo/bin:/data/home/go/bin:/data/home/.bun/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Agent skills shipped with the image. They live in /opt (image layer, so an
# image rebuild updates them) and the entrypoint symlinks each one into
# ${PI_CODING_AGENT_DIR}/skills, which is where pi discovers global skills.
COPY skills/ /opt/pi-docker/skills/

LABEL org.opencontainers.image.title="pi-docker" \
      org.opencontainers.image.description="Persistent container for the pi coding agent and its web UI (pi-web-ui)." \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}"

# /data carries the agent config, the UI state and the npm global prefix.
VOLUME ["/data"]

EXPOSE 8787

# Host allow-list — read this before "it never came online".
# ---------------------------------------------------------------------------
# pi-web-ui rejects any request whose Host header it does not recognise
# (host-guard; a DNS-rebinding defence). The rule is:
#
#   PI_WEB_ALLOW_HOSTS set   -> STRICT: only those hostnames are accepted. The
#                               loopback/LAN fallback below does NOT apply, so
#                               http://127.0.0.1:8787 answers 403 "host not
#                               allowed" — the app is fine, the Host is not.
#   PI_WEB_ALLOW_HOSTS unset -> loopback and private LAN hosts are accepted;
#                               a public domain is refused.
#   PI_WEB_TOKEN set         -> the token is the gate, Host is not checked.
#
# Two consequences for this image:
#   1. The healthcheck below must claim an ALLOWED Host. It connects to
#      loopback but sends the first PI_WEB_ALLOW_HOSTS entry, falling back to
#      127.0.0.1. Plain `fetch()` cannot do this — Host is a forbidden header
#      that undici drops — hence the http.request one-liner.
#   2. `ports:` in the compose files is not published on purpose: reaching the
#      container by IP is exactly the case that gets a bare 403. Add the
#      hostname to PI_WEB_ALLOW_HOSTS if you really need direct access.
#
# /api/health is deliberately unauthenticated (no secrets, probe-friendly) and
# responds even when PI_WEB_TOKEN is set.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["node", "-e", "const h=(process.env.PI_WEB_ALLOW_HOSTS||'127.0.0.1').split(',')[0].trim()||'127.0.0.1';const r=require('http').get({host:'127.0.0.1',port:process.env.PI_WEB_PORT||8787,path:'/api/health',headers:{Host:h}},s=>process.exit(s.statusCode===200?0:1));r.on('error',()=>process.exit(1));r.setTimeout(4000,()=>{r.destroy();process.exit(1)});"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["pi-web-ui", "--no-browser"]
