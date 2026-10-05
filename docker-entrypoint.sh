#!/usr/bin/env bash
#
# Entrypoint for pi-docker.
#
# The image already contains the pi CLI and a seed copy of Herdr and Collie, so
# this script does NOT download anything. It:
#
#   1. (re)creates the persisted directories inside the mounted volume,
#   2. seeds Herdr and Collie into the volume on first start, never over an
#      existing install, so an empty volume boots offline and a self-updated
#      install is never clobbered,
#   3. cleans up the app a pre-Dockerfile compose left in ${NPM_CONFIG_PREFIX},
#   4. makes sure login shells (the panes Collie shows) inherit the same PATH,
#   5. on "serve": starts the headless herdr server and execs the Collie bridge.
#
# A missing/empty volume after `docker compose down -v` is a non-event: the
# stack comes up healthy immediately, with no network access required.
set -euo pipefail

# ---------------------------------------------------------------------------
# Persisted locations
# ---------------------------------------------------------------------------
# Every default keeps the container self-contained under /data, and every one
# can be overridden from the compose file. Collie's and herdr's own defaults
# already live under $HOME, which is the volume — these are explicit so the
# layout is readable from here, not from two other projects' docs.
export HOME="${HOME:-/data/home}"
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-/data/npm}"
export PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-/data/agent}"
export PI_WORKSPACE_DIR="${PI_WORKSPACE_DIR:-/workspace}"
APP_SEED="${PI_APP_SEED:-/opt/pi-docker/seed}"

# The apps. Collie keeps a versioned install root with a `current` symlink, and
# a config dir next to it; herdr keeps a single binary in ~/.local/bin plus its
# state under ~/.herdr. All of it under $HOME = the volume, so `herdr update`
# and `collie update` write somewhere that survives a restart.
export HERDR_INSTALL_DIR="${HERDR_INSTALL_DIR:-${HOME}/.local/bin}"
export HERDR_CONFIG_PATH="${HERDR_CONFIG_PATH:-${HOME}/.config/herdr/config.toml}"
export COLLIE_DIR="${COLLIE_DIR:-${HOME}/.local/share/collie}"
export COLLIE_CONFIG_DIR="${COLLIE_CONFIG_DIR:-${HOME}/.config/collie}"
export COLLIE_STATE_DIR="${COLLIE_STATE_DIR:-${HOME}/.local/state/collie}"
# What the vendor's systemd unit passes to the bridge process: the directory
# holding .env / config.toml. COLLIE_PLUGIN_ROOT belongs in that list too, but it
# is NOT set here — it can only be derived once the app is on the volume, and a
# wrong value is fatal (see the seeding section below).
export HERDR_PLUGIN_CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${COLLIE_CONFIG_DIR}}"

# Canonical search order, prepended to whatever PATH the container arrived with.
# /usr/local (the image's own prefix) comes BEFORE ${NPM_CONFIG_PREFIX}/bin on
# purpose: the pi CLI is managed by the image, so a stale copy persisted in
# /data/npm must not shadow the version the image was built with.
PI_PATH_PREFIX="${PI_CODING_AGENT_DIR}/bin:/usr/local/sbin:/usr/local/bin:${NPM_CONFIG_PREFIX}/bin:${HOME}/.local/bin:${HOME}/.cargo/bin:${HOME}/go/bin:${HOME}/.bun/bin"
export PATH="${PI_PATH_PREFIX}:${PATH}"

# `:-` defaults matter: an unset var would otherwise expand to "" and
# `mkdir -p ""` aborts the whole script under `set -e`.
mkdir -p "${HOME}" "${NPM_CONFIG_PREFIX}" "${PI_CODING_AGENT_DIR}" "${PI_WORKSPACE_DIR}" \
         "${COLLIE_DIR}" "${COLLIE_CONFIG_DIR}" "${COLLIE_STATE_DIR}" "${HERDR_INSTALL_DIR}" \
         "${HOME}/.herdr"

# ---------------------------------------------------------------------------
# Seeding the apps from the image
# ---------------------------------------------------------------------------
# The image carries a seed copy of both apps; the volume is where they actually
# live, because that is the only place their own updaters can keep working.
# Seeding is a local copy — no network, no apt, no npm — and it happens only
# when the destination is missing, so:
#
#   * an empty volume gets a working app in milliseconds,
#   * `collie update` / `herdr update` stay updated across restarts AND across a
#     container recreate (`docker compose down && up`), instead of being
#     silently rolled back to the image's version,
#   * an image rebuild cannot clobber an install the user has updated.
#
# To get back to the image's version, remove the install and restart:
#   rm -rf /data/home/.local/share/collie   (or /data/home/.local/bin/herdr)
# ---------------------------------------------------------------------------
if [ ! -x "${HERDR_INSTALL_DIR}/herdr" ] && [ -x "${APP_SEED}/bin/herdr" ]; then
  echo "[pi-docker] seeding herdr into ${HERDR_INSTALL_DIR} (first start)"
  install -m 0755 "${APP_SEED}/bin/herdr" "${HERDR_INSTALL_DIR}/herdr"
fi

if [ ! -e "${COLLIE_DIR}/current" ] && [ -d "${APP_SEED}/collie/versions" ]; then
  echo "[pi-docker] seeding Collie into ${COLLIE_DIR} (first start)"
  # The trailing `/.` is load-bearing: "${COLLIE_DIR}" was created by the mkdir -p
  # above, and `cp -a src dst` with an existing dst copies *into* it — that
  # yields "${COLLIE_DIR}/collie/versions/...", so "${COLLIE_DIR}/current" never
  # exists, the shim silently falls back to the image's seed, and `collie
  # update` writes into a tree nothing reads.
  cp -a "${APP_SEED}/collie/." "${COLLIE_DIR}/"
  # `current` is a symlink into `versions/`. If the image's copy happened to be
  # absolute, the copy would point back at the image (where an update is
  # ephemeral), so normalise it to a relative link onto the version that is
  # actually there.
  if [ -L "${COLLIE_DIR}/current" ]; then
    current_version="$(basename "$(readlink "${COLLIE_DIR}/current")")"
    if [ -d "${COLLIE_DIR}/versions/${current_version}" ]; then
      ln -sfn "versions/${current_version}" "${COLLIE_DIR}/current"
    fi
  fi
fi

# herdr's first-run setup has nobody to answer it in a headless container, so
# the image ships a minimal config with onboarding off. Only ever seeded when
# absent: ~/.config/herdr/config.toml is yours after that.
if [ ! -e "${HERDR_CONFIG_PATH}" ] && [ -f "${APP_SEED}/herdr/config.toml" ]; then
  mkdir -p "$(dirname "${HERDR_CONFIG_PATH}")"
  cp "${APP_SEED}/herdr/config.toml" "${HERDR_CONFIG_PATH}"
  echo "[pi-docker] seeded ${HERDR_CONFIG_PATH} (edit it freely; it is never overwritten)"
fi

# Collie's *plugin* root is the directory holding package.json and
# herdr-plugin.toml — `current` inside a binary install, or the clone itself for
# a checkout. It is NOT the install root. Collie trusts an injected value without
# checking for its marker, so pointing it one level too high is fatal:
# readFileSync(<root>/package.json) throws, the bridge exits before it binds a
# port, and the container looks like it never came online at all (the healthcheck
# just reports "unhealthy", with the cause one line below the banner).
#
# So only inject a path the marker proves is right; otherwise leave it unset and
# let Collie resolve the root itself (exec path -> herdr-plugin.toml), which is
# what it does for the vendor's own systemd unit.
if [ -z "${COLLIE_PLUGIN_ROOT:-}" ]; then
  for candidate in "${COLLIE_DIR}/current" "${COLLIE_DIR}"; do
    if [ -f "${candidate}/herdr-plugin.toml" ]; then
      export COLLIE_PLUGIN_ROOT="${candidate}"
      break
    fi
  done
  unset candidate
fi

# ---------------------------------------------------------------------------
# Migrated-install cleanup
# ---------------------------------------------------------------------------
# A container built from the pre-Dockerfile compose installed the old web UI and
# the pi CLI into ${NPM_CONFIG_PREFIX} — i.e. into the persisted volume. The
# image owns both now, and leaving the copies behind is worse than dead weight:
# a stale web UI in the volume would keep an outdated server around, and pi
# resolves its packages from the newest copy it finds. Removing them here makes
# the image the single source of truth on an upgrade, without anyone
# remembering a manual step.
#
# Only those two packages are touched. /data/npm is where the agent's own
# `npm install -g <tool>` calls land, so it is never wiped — and a real file the
# user put at ${NPM_CONFIG_PREFIX}/bin/<name> is left alone (only dangling
# symlinks are collected). Idempotent: a second start finds nothing to do.
#
# Guard: this only runs when the image's own Collie is really there. Running
# this script outside the image — a host shell, or a container that shares the
# volume — therefore cannot delete the only working install on the box. (That is
# not theoretical: running an earlier version of this script against a live
# pre-Dockerfile container deleted the running app's own files.)
# ---------------------------------------------------------------------------
PI_IMAGE_PREFIX="${PI_IMAGE_PREFIX:-/usr/local}"
if [ -x "${PI_IMAGE_PREFIX}/bin/collie" ] &&
   [ -n "${NPM_CONFIG_PREFIX}" ] && [ "${NPM_CONFIG_PREFIX}" != "/" ]; then
  NPM_LIB="${NPM_CONFIG_PREFIX}/lib/node_modules"
  for pkg in pi-web-ui @earendil-works/pi-coding-agent; do
    if [ -e "${NPM_LIB}/${pkg}" ]; then
      echo "[pi-docker] removing stale ${pkg} from ${NPM_LIB} (the image provides it now)"
      rm -rf "${NPM_LIB:?}/${pkg}"
    fi
  done
  # An emptied scope dir would otherwise linger as a confusing empty parent.
  rmdir "${NPM_LIB}/@earendil-works" 2>/dev/null || true
  for bin in pi-web-ui pi; do
    link="${NPM_CONFIG_PREFIX}/bin/${bin}"
    if [ -L "${link}" ] && [ ! -e "${link}" ]; then
      echo "[pi-docker] removing dangling ${link}"
      rm -f "${link}"
    fi
  done
fi

# Expose the image's bundled agent skills to pi. They are symlinked, not copied:
# the image stays the single source of truth (an image rebuild updates them) and
# the persisted agent dir holds no duplicate. pi's loader follows symlinked
# directories. Each link is created only when nothing is there, so a skill the
# user replaced with their own real directory is left alone.
SKILLS_SRC=/opt/pi-docker/skills
if [ -d "${SKILLS_SRC}" ]; then
  mkdir -p "${PI_CODING_AGENT_DIR}/skills"
  for skill_dir in "${SKILLS_SRC}"/*/; do
    [ -d "${skill_dir}" ] || continue
    skill_name=$(basename "${skill_dir}")
    skill_link="${PI_CODING_AGENT_DIR}/skills/${skill_name}"
    if [ ! -e "${skill_link}" ] && [ ! -L "${skill_link}" ]; then
      ln -s "${skill_dir%/}" "${skill_link}"
    fi
  done
fi

# The container ENV only covers the main process. The panes Collie shows and
# anything else started as a login shell read this instead, so `pi`, `collie`,
# `herdr` and the rest resolve in there too. Skipped when unprivileged.
if [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
  cat > /etc/profile.d/pi-paths.sh <<EOF
export HOME="${HOME}"
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX}"
export PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR}"
export PI_WORKSPACE_DIR="${PI_WORKSPACE_DIR}"
export HERDR_INSTALL_DIR="${HERDR_INSTALL_DIR}"
export COLLIE_DIR="${COLLIE_DIR}"
export COLLIE_PLUGIN_ROOT="${COLLIE_PLUGIN_ROOT:-}"
export COLLIE_CONFIG_DIR="${COLLIE_CONFIG_DIR}"
export COLLIE_STATE_DIR="${COLLIE_STATE_DIR}"
export PATH="${PI_PATH_PREFIX}:\$PATH"
EOF
fi

# ---------------------------------------------------------------------------
# What this container actually resolved to
# ---------------------------------------------------------------------------
# The original report of this image failing was "it never came online, the logs
# were unhelpful". Twice now the cause has been a host guard refusing a probe
# while the app was fine, so the effective bind, hosts and origins are printed
# on every start, along with the binaries that were found.
# ---------------------------------------------------------------------------
if [ "${PI_QUIET:-0}" != "1" ]; then
  echo "[pi-docker] collie     : $(command -v collie 2>/dev/null || echo 'NOT FOUND') -> $(readlink -f "${COLLIE_DIR}/current" 2>/dev/null || echo 'no install')"
  echo "[pi-docker] herdr      : ${HERDR_INSTALL_DIR}/herdr $([ -x "${HERDR_INSTALL_DIR}/herdr" ] && herdr --version 2>/dev/null | head -n1 || echo '(NOT FOUND)')"
  echo "[pi-docker] pi CLI     : $(command -v pi 2>/dev/null || echo 'NOT FOUND')"
  echo "[pi-docker] data       : home ${HOME}  agent ${PI_CODING_AGENT_DIR}  workspace ${PI_WORKSPACE_DIR}"
  echo "[pi-docker] collie bind: ${COLLIE_HOST:-127.0.0.1}:${COLLIE_PORT:-8787}  (mux=${COLLIE_MUX:-auto} instance=${COLLIE_INSTANCE:-default} skip_serve=${COLLIE_SKIP_SERVE:-0})"
  # Printed because a wrong plugin root is invisible until the bridge dies, and
  # the line it dies on is far below this banner.
  echo "[pi-docker] collie root: ${COLLIE_PLUGIN_ROOT:-unset (Collie resolves it from its own path)}"
  if [ -z "${COLLIE_PUBLIC_HOSTS:-}" ]; then
    echo "[pi-docker] hosts      : unset — Collie applies its own default host rules"
  else
    echo "[pi-docker] hosts      : strict — only ${COLLIE_PUBLIC_HOSTS}; any other Host is refused (this is why an IP:port request looks 'down')"
  fi
  if [ -z "${COLLIE_ALLOWED_ORIGINS:-}" ] && [ -n "${COLLIE_PUBLIC_HOSTS:-}" ]; then
    echo "[pi-docker] WARNING    : COLLIE_ALLOWED_ORIGINS is unset while behind a proxy — the UI will load as an empty page"
  else
    echo "[pi-docker] origins    : ${COLLIE_ALLOWED_ORIGINS:-unset (fine when reached on loopback)}"
  fi
fi

case "${1:-serve}" in
  serve)
    # -----------------------------------------------------------------------
    # Herdr runs as a background server; Collie's bridge mirrors its panes.
    # -----------------------------------------------------------------------
    # `herdr server` is the vendor's "supervised or service-style setup" entry
    # point: it runs the headless server with no client attached, which is
    # exactly a container. The bridge is then the foreground process, so the
    # container's life cycle is Collie's.
    HERDR_LOG="${HOME}/.herdr/server.log"
    # `herdr server` writes only a short banner to stdout; its real log — and any
    # error worth reading — goes to herdr's own file, beside config.toml. On
    # failure both are dumped, so the reason lands in `docker logs`.
    HERDR_SERVER_LOG="$(dirname "${HERDR_CONFIG_PATH}")/herdr-server.log"
    herdr_logs() {
      {
        echo "--- ${HERDR_LOG}" && tail -n 20 "${HERDR_LOG}" 2>/dev/null
        echo "--- ${HERDR_SERVER_LOG}" && tail -n 30 "${HERDR_SERVER_LOG}" 2>/dev/null
      } >&2 || true
    }
    echo "[pi-docker] starting herdr server (log: ${HERDR_SERVER_LOG})"
    herdr server >>"${HERDR_LOG}" 2>&1 &
    herdr_pid=$!
    ready=0
    for _ in $(seq 1 30); do
      if ! kill -0 "${herdr_pid}" 2>/dev/null; then
        echo "[pi-docker] herdr server exited during startup:" >&2
        herdr_logs
        exit 1
      fi
      # Readiness must come from the socket API: `herdr api snapshot` exits
      # non-zero with code server_not_running until the server is actually
      # listening. `herdr session list --json` is NOT a readiness probe — it is a
      # local command that exits 0 with `"running": false` when nothing is up, so
      # it would report "ready" on the first tick and hand the bridge a socket
      # that does not exist yet.
      if herdr api snapshot >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    if [ "${ready}" != "1" ]; then
      echo "[pi-docker] herdr server was not reachable after 30s:" >&2
      herdr_logs
      exit 1
    fi
    echo "[pi-docker] herdr server ready"

    # The bridge, exactly as the vendor's systemd unit starts it: the instance
    # name only distinguishes bridges sharing one binary.
    echo "[pi-docker] starting Collie bridge (instance ${COLLIE_INSTANCE:-default})"
    exec collie _exec-bridge --instance "${COLLIE_INSTANCE:-default}"
    ;;
  *)
    exec "$@"
    ;;
esac
