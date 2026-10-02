#!/usr/bin/env bash
#
# Entrypoint for pi-docker.
#
# The image already contains pi-web-ui and the pi CLI, so this script does NOT
# install anything — it only (re)creates the persisted directories inside the
# mounted volume and makes sure the web UI's terminal tab inherits the same
# PATH as the server process. A missing/empty volume after `docker compose down
# -v` is therefore a non-event: the stack comes up healthy immediately.
set -euo pipefail

# Persisted locations. Every default keeps the container self-contained under
# /data, and every one can be overridden from the compose file.
export HOME="${HOME:-/data/home}"
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-/data/npm}"
export PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-/data/agent}"
export PI_WEB_DATA_DIR="${PI_WEB_DATA_DIR:-${HOME}/.pi-web}"
export PI_WEB_CWD="${PI_WEB_CWD:-/workspace}"

# Canonical search order, prepended to whatever PATH the container arrived with.
# /usr/local (the image's own prefix) comes BEFORE ${NPM_CONFIG_PREFIX}/bin on
# purpose: pi-web-ui is managed by the image — PI_WEB_MANAGED=1 makes the in-app
# updater refuse — so a stale pi-web-ui persisted in /data/npm must not shadow
# the version the image was built with. /data/npm/bin and the $HOME-relative
# directories keep the extra tools the agent installs resolvable.
PI_PATH_PREFIX="${PI_CODING_AGENT_DIR}/bin:/usr/local/sbin:/usr/local/bin:${NPM_CONFIG_PREFIX}/bin:${HOME}/.local/bin:${HOME}/.cargo/bin:${HOME}/go/bin:${HOME}/.bun/bin"
export PATH="${PI_PATH_PREFIX}:${PATH}"

# `:-` defaults matter: an unset var would otherwise expand to "" and
# `mkdir -p ""` aborts the whole script under `set -e`.
mkdir -p "${HOME}" "${NPM_CONFIG_PREFIX}" "${PI_CODING_AGENT_DIR}" "${PI_WEB_DATA_DIR}" "${PI_WEB_CWD}"

# ---------------------------------------------------------------------------
# Migrated-install cleanup
# ---------------------------------------------------------------------------
# A container built from the pre-Dockerfile compose installed pi-web-ui and the
# pi CLI into ${NPM_CONFIG_PREFIX} — i.e. into the persisted volume. The image
# owns them now, and leaving those copies behind is worse than dead weight:
# pi-web-ui picks the *newer* of the installed pi SDK copies, so a stale global
# one silently makes the running app disagree with the version this image was
# built and smoke-tested with. Removing them here makes the image the single
# source of truth on an upgrade, without anyone remembering a manual step.
#
# Only those two packages are touched. /data/npm is where the agent's own
# `npm install -g <tool>` calls land, so it is never wiped — and a real file the
# user put at ${NPM_CONFIG_PREFIX}/bin/<name> is left alone (only dangling
# symlinks are collected). Idempotent: a second start finds nothing to do.
# ---------------------------------------------------------------------------
if [ -n "${NPM_CONFIG_PREFIX}" ] && [ "${NPM_CONFIG_PREFIX}" != "/" ]; then
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

# The container ENV only covers the main process. The web UI's terminal tab and
# anything else started as a login shell read this instead, so `pi`, `npm -g`
# tools and the rest resolve in there too. Skipped when running unprivileged.
if [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
  cat > /etc/profile.d/pi-paths.sh <<EOF
export HOME="${HOME}"
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX}"
export PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR}"
export PI_WEB_DATA_DIR="${PI_WEB_DATA_DIR}"
export PI_WEB_CWD="${PI_WEB_CWD}"
export PATH="${PI_PATH_PREFIX}:\$PATH"
EOF
fi

# A one-line-prefixed summary of what this container actually resolved to. The
# original report of this image failing was "it never came online, the logs were
# unhelpful" — the app had started fine and was answering, but the Host guard
# refused the probe and nothing said so. Printing the effective bind/allow-list
# makes that readable at a glance.
PI_WEB_BIN=$(command -v pi-web-ui 2>/dev/null || echo 'NOT FOUND')
PI_BIN=$(command -v pi 2>/dev/null || echo 'NOT FOUND')
echo "[pi-docker] pi-web-ui : ${PI_WEB_BIN}"
echo "[pi-docker] pi CLI    : ${PI_BIN}"
echo "[pi-docker] data      : ${PI_WEB_DATA_DIR}  agent: ${PI_CODING_AGENT_DIR}  workspace: ${PI_WEB_CWD}"
if [ -z "${PI_WEB_ALLOW_HOSTS:-}" ]; then
  echo "[pi-docker] hosts     : unset — loopback and private LAN accepted, public domains 403"
else
  echo "[pi-docker] hosts     : strict — only ${PI_WEB_ALLOW_HOSTS}; any other Host gets 403 (this is why an IP:port request looks 'down')"
fi
exec "$@"
