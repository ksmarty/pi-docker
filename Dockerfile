# syntax=docker/dockerfile:1
#
# pi-docker — a self-contained, persistent container for Herdr (herdr.dev) and
# the herdr web ui plugin (github.com/devswha/herdr-web-ui), plus the pi coding
# agent CLI.
#
#   docker build -t pi-docker .
#   docker run -d --init --name herdr-web-ui \
#     -v "$PWD/data:/data" -v "$PWD/workspace:/workspace" -p 7317:7317 pi-docker
#
# The web UI is served on 0.0.0.0:7317 and is meant to sit behind your own
# reverse proxy with a login in front of it (Traefik + authentik in the compose
# files).
#
# ---------------------------------------------------------------------------
# Read this before exposing it: the token rule
# ---------------------------------------------------------------------------
# The plugin's own install guide is explicit: "Never bind to 0.0.0.0 or a LAN
# address, or put it behind a proxy other people can reach, without a token
# (HERDR_WEB_TOKEN)" — because anyone who reaches an ungated server can type
# into your terminals.
#
# This image binds 0.0.0.0 (a reverse proxy in a *sibling* container cannot reach
# 127.0.0.1) and does NOT set a token by default: ./compose.ghcr.yaml carries
# HERDR_WEB_TOKEN commented out, one line away from being enabled. With no token
# the plugin authenticates by identity instead, and the vendor's own warning
# applies until you pair a device: a proxied address is open to anyone who
# reaches it. Your Traefik + authentik middleware is that gate. Pair a device
# with a six-digit code (see README, "Logging in").
#
# ---------------------------------------------------------------------------
# Why this file exists (vs. installing at first start)
# ---------------------------------------------------------------------------
#
# The original compose installed the app on first boot, which meant an empty
# data volume re-downloaded everything (minutes of apt + npm) and a container
# that was a bare `node:*-bookworm-slim` with no toolchain until it happened.
#
# This Dockerfile bakes the toolchain, the agent, herdr and a *built* copy of the
# web UI plugin in at build time instead, so the container starts in seconds and
# needs no network. It is single-stage on purpose: the C/C++ toolchain that
# native modules need at install time is *also* what the agent needs later to
# install its own native tools, so removing it would break half the point of the
# image.
#
# ---------------------------------------------------------------------------
# Persistence model — everything lives under /data (one volume)
# ---------------------------------------------------------------------------
#
#   /data/home      HOME          -> herdr state/config/worktrees (~/.herdr,
#                                     ~/.config/herdr), the web UI plugin's
#                                     checkout and per-plugin settings
#                                     (~/.config/herdr/plugins), its pairing,
#                                     push and update state
#                                     (~/.config/herdr-web-ui), the npm cache,
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
#   * The pi CLI and Bun are *packages*: they are installed into the image prefix
#     (/usr/local), which comes FIRST on PATH, ahead of the volume. A stale copy
#     in the volume must never shadow the version the image was built with.
#   * Herdr and the web UI plugin are *seeded* from the image into the volume on
#     first start (see docker-entrypoint.sh). They have their own in-place
#     updaters — `herdr update`, and Settings -> Updates in the web UI — and the
#     whole point of that layout is that an update writes into the volume, so it
#     survives a restart *and* a container recreate. Installing them into /data
#     at build time would leave a fresh, empty volume without its app; installing
#     them only into the image would silently throw away every self-update on the
#     next `compose down`. Seeding both ways is what makes an empty volume boot
#     offline and an updated install stick. The entrypoint never overwrites an
#     existing install, so the image cannot clobber what you updated.
# ---------------------------------------------------------------------------

# Node 26 is the current LTS line (Node 22, the original base, went to
# maintenance in 2026). 24 is still supported and is one build arg away:
#   docker build --build-arg NODE_VERSION=24 .
# Both are exercised by the CI smoke test, which also proves the native modules
# still compile against the chosen Node. Node is not optional here even though
# the web UI is written for Bun: its terminal-attach sidecar requires Node >= 18
# on Linux.
ARG NODE_VERSION=26

FROM node:${NODE_VERSION}-bookworm-slim

ARG PI_CODING_AGENT_VERSION=latest
# "latest" uses the vendor's own installer, which verifies the SHA-256 from the
# release manifest (herdr.dev/latest.json). Set an exact version to make the
# build *assert* it got that release: the installer still fetches latest, so a
# build that silently moved past the pin fails loudly instead of shipping
# something you did not ask for.
ARG HERDR_VERSION=latest
# The web UI plugin is pinned by default, unlike the two above: it is the app
# this image exposes, and `latest` would make an image rebuild a silent upgrade
# of the thing users actually log into. Bump this to update, or leave it and use
# Settings -> Updates in the web UI (that path persists — see the entrypoint).
ARG HERDR_WEB_UI_VERSION=v0.3.50

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
#
# unzip is for Bun's installer, which unpacks its release archive with it and
# fails without a useful message when it is absent — the Bun docs do not list it
# as a requirement. jq is what the entrypoint uses to keep herdr's plugin
# registry pointing at the volume.
#
# Deliberately NOT set: NODE_ENV=production. It would make `npm install` in the
# agent's own projects skip devDependencies, which is a surprising thing for a
# coding agent's environment to do.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less procps ripgrep unzip \
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
# Herdr seed
# ---------------------------------------------------------------------------
# Installed into /opt/pi-docker/seed, which is the image's copy — the entrypoint
# copies it into $HOME (the volume) on first start, and never over an existing
# install. The seed stays in the image so an image rebuild can refresh it for
# anyone who has not self-updated.
#
# `herdr` is NOT wrapped in a shim: its installer defaults to $HOME/.local/bin,
# which is already the persisted, on-PATH location, so the binary is simply
# seeded there.
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

# The herdr config the entrypoint seeds into the volume on first start, and the
# one the plugin bake below starts from. It is a *minimal* config (onboarding off,
# headless pane size) — the plugin registry and per-plugin settings are written
# into the volume at start, never into the image.
COPY config/herdr-config.toml /opt/pi-docker/seed/herdr/config.toml

# ---------------------------------------------------------------------------
# Bun (in the image prefix)
# ---------------------------------------------------------------------------
# The web UI is a Bun program: its plugin manifest declares
#   startup: bun scripts/plugin.ts start
# so herdr runs it with Bun, and the plugin's own prerequisite list is Bun >= 1.4
# plus Node >= 18 (already here).
#
# BUN_INSTALL is exported *only for this build step*, on purpose. Installing Bun
# into /usr/local puts the image's copy ahead of the volume on PATH, while
# leaving BUN_INSTALL unset at runtime means any `bun install -g <tool>` the
# agent runs later lands in ~/.bun — i.e. under /data, where it survives a
# restart, a recreate and an image rebuild.
#
# The version check is here because the plugin's first build step reports a
# missing or too-old Bun itself, and this build would otherwise fail a minute
# later with that message buried in the installer output.
RUN set -eux; \
    curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash; \
    /usr/local/bin/bun --version; \
    got="$(/usr/local/bin/bun --version)"; \
    major="${got%%.*}"; minor="$(echo "${got}" | cut -d. -f2)"; \
    if [ "${major}" -lt 1 ] || { [ "${major}" -eq 1 ] && [ "${minor}" -lt 4 ]; }; then \
      echo "ERROR: the web UI needs Bun >= 1.4, the installer gave ${got}." >&2; \
      exit 1; \
    fi

# ---------------------------------------------------------------------------
# The web UI plugin, built at image-build time into a staging HOME
# ---------------------------------------------------------------------------
# `herdr plugin install` clones the repository, runs `bun install` and
# `bun run build` (about a minute), and registers the plugin. Doing it here is
# what lets a container start with no network, no clone and no build.
#
# HOME is redirected to the staging directory for this step so the whole result
# lands in /opt/pi-docker/seed/home/.config/herdr, which the entrypoint copies
# into the volume. HERDR_CONFIG_PATH must be redirected too: the runtime ENV
# below points it at /data/home, and herdr would otherwise write the plugin
# registry into the image's *runtime* path during the build.
#
# `.git` is removed from the checkout afterwards. It is ~48M of history the
# running plugin never reads, and it does not break updates: herdr records
# `resolved_commit` in its registry and re-clones into a new directory for a
# reinstall, and the in-app updater builds into HERDR_WEB_STATE_DIR rather than
# mutating this checkout.
#
# The `grep -q enabled` is the build's own assertion that the plugin is not just
# present but registered and enabled — a plugin that installs but lands disabled
# is a container that serves nothing, and the failure would otherwise appear only
# at runtime as an unhealthy container.
RUN set -eux; \
    export HOME=/opt/pi-docker/seed/home; \
    export HERDR_CONFIG_PATH="${HOME}/.config/herdr/config.toml"; \
    mkdir -p "$(dirname "${HERDR_CONFIG_PATH}")" /opt/pi-docker/seed/home/.config/herdr; \
    cp /opt/pi-docker/seed/herdr/config.toml "${HERDR_CONFIG_PATH}"; \
    /opt/pi-docker/seed/bin/herdr plugin install devswha/herdr-web-ui \
      --ref "${HERDR_WEB_UI_VERSION}" --yes; \
    /opt/pi-docker/seed/bin/herdr plugin list; \
    /opt/pi-docker/seed/bin/herdr plugin list | grep -q 'devswha.herdr-web-ui'; \
    /opt/pi-docker/seed/bin/herdr plugin list | grep -q 'enabled'; \
    # The registry records three absolute paths per entry (measured schema:
    # plugin_root, manifest_path, source.managed_path, keyed by plugin_id). They
    # are written here to point into the *seed* — deterministic, because HOME was
    # redirected above — and the entrypoint repairs them to the volume on first
    # start. Asserting they live under the seed is what catches a build that
    # accidentally records the build host's own HOME instead.
    jq -e 'all(.[]; (.plugin_root | startswith("/opt/pi-docker/seed/home")))' \
      "${HOME}/.config/herdr/plugins.json" >/dev/null; \
    jq -e 'all(.[]; (.manifest_path != null) and (.source.managed_path != null))' \
      "${HOME}/.config/herdr/plugins.json" >/dev/null; \
    rm -rf "${HOME}"/.config/herdr/plugins/github/*/.git; \
    test -f "${HOME}"/.config/herdr/plugins.json; \
    find "${HOME}/.config/herdr/plugins" -maxdepth 3 -name herdr-plugin.toml; \
    du -sh "${HOME}/.config/herdr/plugins"

# The persisted layout. Created here so the volume inherits sane ownership even
# when Docker creates it on first run.
RUN mkdir -p /data/home /data/agent /data/npm /workspace

# Runtime environment. HOME and NPM_CONFIG_PREFIX point into the volume, which is
# what makes both the agent's data and any tool it installs survive restarts.
# Every $HOME-relative tool directory worth having is on PATH as well.
#
# HERDR_WEB_HOST / HERDR_WEB_PORT are this image's knobs, and they are NOT the
# plugin's own variables: the plugin reads its settings from
# <herdr plugin config-dir>/env, never from the container environment, so the
# entrypoint translates these two into that file. That indirection is why the
# defaults live here and the file is written at start rather than build time: a
# value baked into the image's copy of the file would be frozen, and the volume
# copy has to win.
#
#   HERDR_WEB_HOST=0.0.0.0
#     A reverse proxy in *another container* cannot reach this container's
#     127.0.0.1 (the plugin's loopback default assumes a proxy on the same host,
#     or network_mode: host). The cost is that everything inside the container
#     can reach the port: here that is root, and nothing else. Set it to
#     127.0.0.1 in your compose file if your proxy is on the host, but note that
#     the web UI is then unreachable from a sibling Traefik container.
#   HERDR_PROCESS_DETECTION=child-groups
#     Container runtimes often do not expose the foreground process group the way
#     herdr's default detection expects.
ENV HOME=/data/home \
    NPM_CONFIG_PREFIX=/data/npm \
    PI_CODING_AGENT_DIR=/data/agent \
    PI_WORKSPACE_DIR=/workspace \
    PI_APP_SEED=/opt/pi-docker/seed \
    HERDR_INSTALL_DIR=/data/home/.local/bin \
    HERDR_CONFIG_PATH=/data/home/.config/herdr/config.toml \
    HERDR_PROCESS_DETECTION=child-groups \
    HERDR_WEB_HOST=0.0.0.0 \
    HERDR_WEB_PORT=7317 \
    PATH=/data/agent/bin:/usr/local/sbin:/usr/local/bin:/data/npm/bin:/data/home/.local/bin:/data/home/.cargo/bin:/data/home/go/bin:/data/home/.bun/bin:/usr/sbin:/usr/bin:/sbin:/bin

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

LABEL org.opencontainers.image.title="pi-docker" \
      org.opencontainers.image.description="Persistent container for Herdr, the herdr web ui and the pi coding agent." \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.source="https://github.com/ksmarty/pi-docker"

# The two things that persist: /data (agent config, herdr's state, the web UI
# plugin and its pairing state) and /workspace (the projects the panes work in).
# Both are declared so a bare `docker run` with no mounts still keeps them in
# anonymous volumes; the deployment mounts them explicitly instead (compose maps
# ${USERDIR}/data/pi/data and .../workspace). Nothing else may be added here —
# the image's own packages belong in /usr/local, where an update can replace them.
VOLUME ["/data", "/workspace"]

EXPOSE 7317

# Healthcheck: the plugin's own /api/health on loopback. 200 *and* `"ok":true`.
# ---------------------------------------------------------------------------
# Measured contract (plugin 0.3.50, both with and without a token):
#
#   GET /api/health  ->  200  {"ok":true,"herdr":{"version":...,"protocol":22},
#                              "auth":{...},"web_ui":{"boot_id":...,"revision":...}}
#   GET /api/health  with a foreign Host header -> 200, same body (no host guard)
#   GET / (the PWA shell)                       -> 200, unauthenticated
#   GET /health  (no /api prefix)               -> 200 *HTML*, i.e. the SPA — not a
#                                                  health endpoint; do not probe it
#
# Two things this probe deliberately does not do:
#
#   * It does not claim a Host header. The app this image used to ship had a host
#     allow-list that 403'd a foreign Host, which is why the old probe sent one;
#     this plugin has none, as the measurement above shows. Asserting a header the
#     app ignores would only make the probe test something else.
#   * It does not assert that anyone can *log in*. `ok` is the vendor's own
#     liveness field and it is answered unauthenticated; whether a device is
#     paired is a human step (see the README). What `ok:true` does prove is that
#     both halves are alive — the plugin, which reports `web_ui.boot_id`, and its
#     socket link to the herdr server. That is the failure this probe exists to
#     catch: a container whose server is up but whose UI never came up.
#
# The port is read from the plugin's own env file first, because that file wins
# over the container environment — the same value the entrypoint prints and the
# same one the readiness check waits on.
#
# On failure it prints the status code and body to stderr, which lands in
# `docker inspect`'s health log: "unhealthy" with no reason was the whole
# complaint about the previous image.
#
# A cold boot on an empty volume seeds herdr, the plugin and its config before
# the server binds, so the start period is generous; `docker compose up --wait`
# treats an unhealthy container as a failed start.
HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=5 \
  CMD ["node", "-e", "const fs=require('fs'),path=require('path');const cfg=path.join(process.env.HOME||'/data/home','.config/herdr/plugins/config/devswha.herdr-web-ui');let port=Number(process.env.HERDR_WEB_PORT||7317);for(const f of ['.env','env']){try{const m=fs.readFileSync(path.join(cfg,f),'utf8').match(/^[ \\t]*PORT[ \\t]*=[ \\t]*(\\d+)/m);if(m){port=Number(m[1]);break}}catch(e){}}const fail=m=>{console.error('health probe failed on port '+port+': '+m);process.exit(1)};const r=require('http').get({host:'127.0.0.1',port,path:'/api/health'},s=>{let b='';s.on('data',c=>b+=c);s.on('end',()=>{const ok=s.statusCode===200&&(b.includes('\"ok\":true')||b.includes('\"ok\": true'));if(!ok)return fail('status='+s.statusCode+' body='+b.slice(0,300));process.exit(0)})});r.on('error',e=>fail(e.message));r.setTimeout(4000,()=>{r.destroy();fail('timed out')});"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
# "serve" is the image's own keyword: seed what is missing, start the headless
# herdr server in the foreground and let its startup hook bring the web UI up.
# Anything else is exec'd as-is, so `docker run --rm -it pi-docker bash` gets you
# a shell inside the real setup.
CMD ["serve"]
