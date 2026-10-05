#!/usr/bin/env bash
#
# Runs INSIDE the image, piped in with `bash -lc "$(cat scripts/ci-migrated-install.sh)"`.
# Covers the entrypoint's migrated-install cleanup, which is what makes an
# upgrade from the pre-Dockerfile compose automatic instead of a manual rm -rf.
#
# The packages it removes are the ones that compose installed into the persisted
# npm prefix: the old web UI and the pi CLI. Neither is installed that way any
# more, so a copy in the volume is stale by definition — and a stale web UI in
# /data/npm would keep an outdated server around next to the image's own.
#
# Note that the entrypoint has already run once by the time this script does (it
# is the image ENTRYPOINT), which is why the guard below passes in CI: the image's
# /usr/local/bin/collie is really there.
#
# `-E` and the ERR trap below make a bare failing command annotate itself: job
# logs need admin rights over the repository, so an annotation is the only reason
# that reaches whoever is debugging.
set -eEuo pipefail

trap 'rc=$?; echo "::error::ci-migrated-install failed at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

# The paths default to the image layout; they are overridable so this test can
# also be run by hand (with a throwaway NPM_CONFIG_PREFIX and PI_IMAGE_PREFIX)
# without touching a real /data — a mistake worth making impossible, since the
# same cleanup deletes a working install if it points at one.
ENTRYPOINT="${ENTRYPOINT:-/usr/local/bin/docker-entrypoint.sh}"
NPM_PREFIX="${NPM_CONFIG_PREFIX:-/data/npm}"
NPM_LIB="${NPM_PREFIX}/lib/node_modules"
NPM_BIN="${NPM_PREFIX}/bin"

seed() {
  mkdir -p "${NPM_LIB}/pi-web-ui" "${NPM_LIB}/@earendil-works/pi-coding-agent" \
           "${NPM_LIB}/some-user-tool" "${NPM_BIN}"
  # Dangling links, exactly like the ones a migrated install leaves behind.
  ln -sf "${NPM_LIB}/pi-web-ui/nope" "${NPM_BIN}/pi-web-ui"
  ln -sf "${NPM_LIB}/@earendil-works/pi-coding-agent/nope" "${NPM_BIN}/pi"
}

# --------------------------------------------------------------------------
# 1. the migrated copies are removed; anything else in /data/npm survives
# --------------------------------------------------------------------------
seed
"${ENTRYPOINT}" true
test ! -e "${NPM_LIB}/pi-web-ui"
test ! -e "${NPM_LIB}/@earendil-works/pi-coding-agent"
test ! -L "${NPM_BIN}/pi-web-ui"
test ! -L "${NPM_BIN}/pi"
test -d "${NPM_LIB}/some-user-tool"
test ! -e "${NPM_LIB}/@earendil-works"
echo "OK: migrated installs removed, the agent's own tools kept"

# --------------------------------------------------------------------------
# 2. a real file the user put in bin/ is not a dangling symlink — leave it
# --------------------------------------------------------------------------
printf '#!/bin/sh\necho mine\n' > "${NPM_BIN}/mytool"
chmod +x "${NPM_BIN}/mytool"
"${ENTRYPOINT}" true
test -x "${NPM_BIN}/mytool"
echo "OK: non-symlink bin entry kept"

# --------------------------------------------------------------------------
# 3. safety guard: with no image-owned app to fall back on, deleting the
#    persisted one would remove the only working install on the box. That is
#    not theoretical — an earlier version of this script was run against a live
#    pre-Dockerfile container and deleted the running app's files.
# --------------------------------------------------------------------------
seed
PI_IMAGE_PREFIX=/nonexistent "${ENTRYPOINT}" true
test -e "${NPM_LIB}/pi-web-ui"
test -e "${NPM_LIB}/@earendil-works/pi-coding-agent"
test -L "${NPM_BIN}/pi-web-ui"
echo "OK: cleanup skipped when the image copy is absent"

# --------------------------------------------------------------------------
# 4. idempotent: a second start with nothing to clean is a no-op
# --------------------------------------------------------------------------
"${ENTRYPOINT}" true
"${ENTRYPOINT}" true
test -d "${NPM_LIB}/some-user-tool"
echo "OK: idempotent"

# --------------------------------------------------------------------------
# 5. seeding never overwrites an install that is already there — this is what
#    keeps `collie update` / `herdr update` from being rolled back by a restart
# --------------------------------------------------------------------------
COLLIE_DIR="${COLLIE_DIR:-/data/home/.local/share/collie}"
HERDR_INSTALL_DIR="${HERDR_INSTALL_DIR:-/data/home/.local/bin}"
printf '#!/bin/sh\necho updated-marker\n' > "${COLLIE_DIR}/current/bin/collie.updatetest"
chmod +x "${COLLIE_DIR}/current/bin/collie.updatetest"
marker_before="$(cat "${COLLIE_DIR}/current/bin/collie.updatetest")"
"${ENTRYPOINT}" true
test -f "${COLLIE_DIR}/current/bin/collie.updatetest"
test "$(cat "${COLLIE_DIR}/current/bin/collie.updatetest")" = "${marker_before}"
test -x "${HERDR_INSTALL_DIR}/herdr"
rm -f "${COLLIE_DIR}/current/bin/collie.updatetest"
echo "OK: an existing install is left alone by the seeding step"

echo "migrated-install test OK"
