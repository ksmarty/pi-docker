#!/usr/bin/env bash
#
# Runs INSIDE the image, piped in with `bash -lc "$(cat scripts/ci-migrated-install.sh)"`.
# Covers the entrypoint's migrated-install cleanup, which is what makes an
# upgrade from the pre-Dockerfile compose automatic instead of a manual rm -rf.
set -euo pipefail

# The paths default to the image layout; they are overridable so this test can
# also be run by hand (with a throwaway NPM_CONFIG_PREFIX) without touching a
# real /data — which is a mistake worth making impossible, since the same
# cleanup deletes a working install if it points at one.
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
# 3. safety guard: with no image-owned install to fall back on, deleting the
#    persisted one would remove the only working pi-web-ui on the box
# --------------------------------------------------------------------------
seed
PI_WEB_IMAGE_PREFIX=/nonexistent "${ENTRYPOINT}" true
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

echo "migrated-install test OK"
