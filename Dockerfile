# syntax=docker/dockerfile:1
#
# pi-docker — a self-contained, persistent container for Herdr (herdr.dev) and
# the Collie PWA (colliepwa.dev), plus the pi coding agent CLI.
#
#   docker build -t pi-docker .
#   docker run -d --init --name collie \
#     -v "$PWD/data:/data" -v "$PWD/workspace:/workspace" pi-docker
#
# Collie is served on 0.0.0.0:8787 and is meant to sit behind your own reverse
# proxy with a login in front of it (Traefik + authentik in the compose files).
# Reaching it by IP only works when that IP/hostname is acceptable to Collie's
# host guard — see "Hosts and origins" below.
#
# ---------------------------------------------------------------------------
# Why this file exists (vs. installing at first start)
# ---------------------------------------------------------------------------
#
# The original compose installed the app on first boot, which meant an empty
# data volume re-downloaded everything (minutes of apt + npm) and a container
# that was a bare `node:*-bookworm-slim` with no toolchain until it happened.
#
# This Dockerfile bakes the toolchain and the agent in at build time instead, so
# the container starts in seconds. It is single-stage on purpose: the C/C++
# toolchain that native modules need at install time is *also* what the agent
# needs later to install its own native tools, so removing it would break half
# the point of the image.
#
# ---------------------------------------------------------------------------
# Persistence model — everything lives under /data (one volume)
# ---------------------------------------------------------------------------
#
#   /data/home      HOME          -> herdr state/config/worktrees (~/.herdr,
#                                     ~/.config/herdr), Collie's install root
#                                     (~/.local/share/collie), its config
#                                     (~/.config/collie) and state
#                                     (~/.local/state/collie), the npm cache,
#                                     pip --user, ~/.local/bin, ~/.cargo, ~/go,
#                                     ~/.bun — all persisted
#   /data/agent     PI_CODING_AGENT_DIR -> pi config, API keys, sessions,
#                                     packages/extensions, and its own bin/
#   /data/npm       NPM_CONFIG_PREFIX   -> `npm install -g <tool>` from inside
#                                     the agent lands here and survives restarts
#   /workspace      PI_WORKSPACE_DIR -> the agent's project files
#
# Two different rules apply to the two kinds of software here, and the split is
# deliberate:
#
#   * The pi CLI is a *package*: npm installs it into the image prefix
#     (/usr/local), which comes FIRST on PATH, ahead of /data/npm. A stale copy
#     in the volume must never shadow the version the image was built with.
#   * Herdr and Collie are *seeded* from the image into the volume on first
#     start (see docker-entrypoint.sh). They have their own in-place updaters —
#     `herdr update`, `collie update` — and the whole point of that layout is
#     that an update writes into the volume, so it survives a restart *and* a
#     container recreate. Installing them into /data at build time would leave a
#     fresh, empty volume without its app; installing them only into the image
#     would silently throw away every self-update on the next `compose down`.
#     Seeding both ways is what makes an empty volume boot offline and an
#     updated install stick. The entrypoint never overwrites an existing
#     install, so the image cannot clobber what you updated.
# ---------------------------------------------------------------------------

# Node 26 is the current LTS line (Node 22, the original base, went to
# maintenance in 2026). 24 is still supported and is one build arg away:
#   docker build --build-arg NODE_VERSION=24 .
# Both are exercised by the CI smoke test, which also proves the native modules
# still compile against the chosen Node (they have no linux prebuild).
ARG NODE_VERSION=26

FROM node:${NODE_VERSION}-bookworm-slim

# Tooling versions — override at build time to pin, e.g.
#   docker build --build-arg COLLIE_VERSION=v1.16.2 .
ARG PI_CODING_AGENT_VERSION=latest
# "latest" uses each vendor's own installer, which verifies the SHA-256 from the
# release manifest (herdr.dev/latest.json, collie's .sha256 asset). Set an exact
# version to make the build *assert* it got that release: the installer still
# fetches latest, so a build that silently moved past the pin fails loudly
# instead of shipping something you did not ask for.
ARG HERDR_VERSION=latest
ARG COLLIE_VERSION=latest

# Build metadata, passed by .github/workflows/*.yml
ARG VERSION=dev
ARG COMMIT=unknown

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

# The C/C++ toolchain is required BEFORE npm touches any native module (they
# compile from source on Linux), and it is kept in the final image so the agent
# can rebuild native modules later. curl/awk are what the vendor installers need;
# ca-certificates is what makes their HTTPS fetches work at all.
# Deliberately NOT set: NODE_ENV=production. It would make `npm install` in the
# agent's own projects skip devDependencies, which is a surprising thing for a
# coding agent's environment to do.
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

# The pi coding agent CLI, installed into the image prefix (/usr/local) and NOT
# the persisted /data/npm: a fresh, empty data volume must never leave the
# container without it. The cache mounts speed up rebuilds (and the arm64 leg of
# a release) only — they are not part of the image. node-gyp headers are
# architecture-independent, so they are shared between platforms.
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.cache/node-gyp \
    npm install --global "@earendil-works/pi-coding-agent@${PI_CODING_AGENT_VERSION}"

# ---------------------------------------------------------------------------
# Herdr + Collie seeds
# ---------------------------------------------------------------------------
# Both are installed into /opt/pi-docker/seed, which is the image's copy — the
# entrypoint copies it into $HOME (the volume) on first start, and never over an
# existing install. The seed stays in the image so an image rebuild can refresh
# it for anyone who has not self-updated.
#
# herdr: the vendor installer checks the SHA-256 from herdr.dev/latest.json (the
# same manifest `herdr update` uses), so installs and updates agree on what
# "latest" means. It needs no TTY.
RUN set -eux; \
    mkdir -p /opt/pi-docker/seed/bin; \
    curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/opt/pi-docker/seed/bin sh; \
    /opt/pi-docker/seed/bin/herdr --version; \
    got="$(/opt/pi-docker/seed/bin/herdr --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"; \
    want="${HERDR_VERSION#v}"; \
    if [ "${HERDR_VERSION}" != "latest" ] && [ "${got}" != "${want}" ]; then \
      echo "ERROR: asked for herdr ${HERDR_VERSION}, the installer fetched ${got}." >&2; \
      echo "Bump ARG HERDR_VERSION (or use latest) and rebuild." >&2; \
      exit 1; \
    fi

# collie: same idea, installed standalone (not as a herdr plugin) so it has a
# versioned install root of its own: <root>/current -> versions/vX.Y.Z. That
# layout is what makes `collie update` and `collie update --rollback` work, and
# it is why the entrypoint can seed it with a plain copy.
#
# COLLIE_TAG is the installer's pin, and it validates the shape of what it is
# given: a release TAG (`v1.16.2`), not a bare version. Both spellings of the
# build arg are accepted below for that reason.
#
# The version check reads the version off the install root's symlink instead of
# parsing `collie --version` — the layout is the contract `collie update`
# depends on, so it is the more reliable of the two.
#
# `_exec-bridge` is the vendor's *internal* verb, one the systemd unit in their
# deployment docs starts and the one this image runs in the foreground. A rename
# upstream would otherwise only show up as a container that never comes online,
# so the build refuses to produce an image whose Collie no longer has it.
RUN set -eux; \
    export COLLIE_DIR=/opt/pi-docker/seed/collie; \
    if [ "${COLLIE_VERSION}" != "latest" ]; then \
      case "${COLLIE_VERSION}" in v*) export COLLIE_TAG="${COLLIE_VERSION}";; *) export COLLIE_TAG="v${COLLIE_VERSION}";; esac; \
    fi; \
    curl -fsSL https://colliepwa.dev/install.sh | sh; \
    test -x /opt/pi-docker/seed/collie/current/bin/collie; \
    /opt/pi-docker/seed/collie/current/bin/collie --help >/dev/null; \
    got="$(basename "$(readlink -f /opt/pi-docker/seed/collie/current)")"; \
    want="${COLLIE_VERSION#v}"; \
    if [ "${COLLIE_VERSION}" != "latest" ] && [ "${got}" != "${want}" ]; then \
      echo "ERROR: asked for collie ${COLLIE_VERSION}, the installer fetched ${got}." >&2; \
      echo "Bump ARG COLLIE_VERSION (or use latest) and rebuild." >&2; \
      exit 1; \
    fi; \
    grep -q -- _exec-bridge /opt/pi-docker/seed/collie/current/bin/collie || { \
      echo "ERROR: this Collie build has no _exec-bridge — the foreground bridge command changed." >&2; \
      echo "See https://colliepwa.dev/docs/deployment (systemd ExecStart) for the current one." >&2; \
      exit 1; \
    }

# `collie` on PATH, resolving the install root at runtime. The vendor installer
# puts its launcher in ~/.local/bin, but at build time $HOME is /root: that copy
# would point at the image's seed instead of the volume, so `collie update`
# would write into an image layer and lose the update on the next recreate.
# This wrapper is explicit about it — COLLIE_DIR wins, the volume default is
# next, and the image seed is the last resort so `collie` still works when the
# entrypoint never ran (docker run --entrypoint bash).
RUN printf '%s\n' \
      '#!/bin/sh' \
      '# Resolve Collie'"'"'s install root at runtime: the volume copy supports in-place' \
      '# self-update (`collie update`), the image seed is only a fallback.' \
      'set -eu' \
      'root="${COLLIE_DIR:-${HOME:-/root}/.local/share/collie}"' \
      'if [ ! -x "$root/current/bin/collie" ] && [ -x "${PI_APP_SEED:-/opt/pi-docker/seed}/collie/current/bin/collie" ]; then' \
      '  root="${PI_APP_SEED:-/opt/pi-docker/seed}/collie"' \
      'fi' \
      'if [ ! -x "$root/current/bin/collie" ]; then' \
      '  echo "collie: no install at $root — is the /data volume mounted and did the entrypoint run?" >&2' \
      '  exit 127' \
      'fi' \
      'COLLIE_DIR="$root" exec "$root/current/bin/collie" "$@"' \
      > /usr/local/bin/collie \
 && chmod +x /usr/local/bin/collie \
 && /usr/local/bin/collie --help >/dev/null
# `herdr` is NOT wrapped: its installer defaults to $HOME/.local/bin, which is
# already the persisted, on-PATH location, so the binary is simply seeded there.

# The persisted layout. Created here so the volume inherits sane ownership even
# when Docker creates it on first run.
RUN mkdir -p /data/home /data/agent /data/npm /workspace

# Runtime environment. HOME and NPM_CONFIG_PREFIX point into the volume, which
# is what makes both the agent's data and any tool it installs survive restarts.
# Every $HOME-relative tool directory worth having is on PATH as well.
ENV HOME=/data/home \
    NPM_CONFIG_PREFIX=/data/npm \
    PI_CODING_AGENT_DIR=/data/agent \
    PI_WORKSPACE_DIR=/workspace \
    PI_APP_SEED=/opt/pi-docker/seed \
    COLLIE_PORT=8787 \
    COLLIE_DIR=/data/home/.local/share/collie \
    COLLIE_CONFIG_DIR=/data/home/.config/collie \
    COLLIE_STATE_DIR=/data/home/.local/state/collie \
    HERDR_INSTALL_DIR=/data/home/.local/bin \
    HERDR_CONFIG_PATH=/data/home/.config/herdr/config.toml \
    HERDR_PROCESS_DETECTION=child-groups \
    PATH=/data/agent/bin:/usr/local/sbin:/usr/local/bin:/data/npm/bin:/data/home/.local/bin:/data/home/.cargo/bin:/data/home/go/bin:/data/home/.bun/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Collie's own runtime defaults. These are what a bare `docker run` needs; the
# compose files add the deployment-specific ones (public host, allowed origin).
#
#   COLLIE_HOST=0.0.0.0 + COLLIE_ALLOW_NON_LOOPBACK_BIND=1
#     A reverse proxy in *another container* cannot reach this container's
#     127.0.0.1 (the docs' loopback advice assumes a proxy on the same host, or
#     network_mode: host). Collie refuses a non-loopback bind unless asked
#     explicitly, which is exactly the flag below. The cost is that everything
#     inside the container can reach the port: here that is root, and nothing
#     else. Drop both to stay loopback-only if your proxy is on the host.
#   COLLIE_SKIP_SERVE=1
#     Do not run `tailscale serve` — the reverse proxy is the only front door.
#     This is deployment Variant C.
#   COLLIE_MUX=herdr
#     Without this Collie probes for a live Herdr socket, a tmux server and
#     zellij sessions, and refuses to start when it finds none or several.
#   HERDR_PROCESS_DETECTION=child-groups
#     Container runtimes often do not expose the foreground process group the way
#     herdr's default detection expects.
ENV COLLIE_HOST=0.0.0.0 \
    COLLIE_ALLOW_NON_LOOPBACK_BIND=1 \
    COLLIE_SKIP_SERVE=1 \
    COLLIE_MUX=herdr \
    COLLIE_INSTANCE=default \
    HERDR_PLUGIN_CONFIG_DIR=/data/home/.config/collie

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Agent skills shipped with the image. They live in /opt (image layer, so an
# image rebuild updates them) and the entrypoint symlinks each one into
# ${PI_CODING_AGENT_DIR}/skills, which is where pi discovers global skills.
COPY skills/ /opt/pi-docker/skills/

# Herdr ships an agent skill of its own (`herdr --skill`, the same text it tells
# agents to fetch when they need to drive panes, tabs and workspaces). Generate
# it from the installed binary rather than vendoring a copy, so it always
# describes the version actually in the image. It lands in the same directory as
# the hand-written skills, so the entrypoint's symlink loop publishes it to the
# agent without any extra wiring.
RUN mkdir -p /opt/pi-docker/skills/herdr \
 && /opt/pi-docker/seed/bin/herdr --skill > /opt/pi-docker/skills/herdr/SKILL.md \
 && test -s /opt/pi-docker/skills/herdr/SKILL.md \
 && head -n 2 /opt/pi-docker/skills/herdr/SKILL.md

# The herdr config the entrypoint seeds into the volume on first start.
COPY config/herdr-config.toml /opt/pi-docker/seed/herdr/config.toml

LABEL org.opencontainers.image.title="pi-docker" \
      org.opencontainers.image.description="Persistent container for Herdr, the Collie PWA and the pi coding agent." \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.source="https://github.com/ksmarty/pi-docker"

# /data carries the agent config, herdr's state and Collie's install root.
VOLUME ["/data"]

EXPOSE 8787

# Hosts and origins — read this before "it never came online".
# ---------------------------------------------------------------------------
# Collie refuses a request whose Host it does not recognise (a DNS-rebinding
# defence), and its UI will not load at all unless the origin you reach it on is
# in COLLIE_ALLOWED_ORIGINS — the docs are blunt about the failure mode: "Without
# this setting, the UI will load as an empty page." Both are set in the compose
# files. The rule:
#
#   COLLIE_PUBLIC_HOSTS set  -> only those hostnames are accepted; a bare
#                               IP, a container name or a stray Host header is
#                               refused. The healthcheck below therefore claims
#                               an ALLOWED host while connecting to loopback.
#   COLLIE_PUBLIC_HOSTS unset -> this is NOT an open door either: Collie still
#                               applies its own default host rules.
#
# The healthcheck probes /api/health, which is unauthenticated on purpose (no
# secrets, probe-friendly) and answers on loopback. It cannot use fetch():
# Host is a forbidden header that undici silently drops, so the probe would
# claim the wrong hostname and get refused — that was the shipped-in-v0.1.0 bug,
# where the app was up and answering while the container reported unhealthy.
# http.request is used for the same reason it is documented in AGENTS.md.
#
# Timings: Collie binds after it has found the multiplexer socket, and on a cold
# boot the image is also seeding the app into an empty volume. A short
# --start-period would mark the container unhealthy in that window, and
# `docker compose up --wait` treats an unhealthy container as a failed start.
HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=5 \
  CMD ["node", "-e", "const h=((process.env.COLLIE_PUBLIC_HOSTS||'127.0.0.1').split(',')[0].trim().split(':')[0])||'127.0.0.1';const r=require('http').get({host:'127.0.0.1',port:Number(process.env.COLLIE_PORT||8787),path:'/api/health',headers:{Host:h}},s=>process.exit(s.statusCode===200?0:1));r.on('error',()=>process.exit(1));r.setTimeout(4000,()=>{r.destroy();process.exit(1)});"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
# "serve" is the image's own keyword: start the headless herdr server, then exec
# the Collie bridge in the foreground. Anything else is exec'd as-is, so
# `docker run --rm -it pi-docker bash` gets you a shell inside the real setup.
CMD ["serve"]
