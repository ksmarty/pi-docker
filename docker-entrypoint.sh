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

exec "$@"
