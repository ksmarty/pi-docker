#!/usr/bin/env bash
#
# Runs INSIDE the image, piped in with `bash -lc "$(cat scripts/ci-migrated-install.sh)"`.
# Covers the entrypoint's two state-preparation rules:
#
#   * the migrated-install cleanup, which is what makes an upgrade from the
#     pre-Dockerfile compose automatic instead of a manual rm -rf, and
#   * the seeding rule — copy only when the destination is missing — which is what
#     keeps `herdr update` / `herdr plugin update` from being rolled back by a
#     restart.
#
# The packages the cleanup removes are the ones the old compose installed into the
# persisted npm prefix: the previous web UI and the pi CLI. Neither is installed
# that way any more, so a copy in the volume is stale by definition — and a stale
# web UI in /data/npm would keep an outdated server next to the image's own.
#
# The entrypoint has already run once by the time this script does (it is the
# image ENTRYPOINT), so the image seeds really do exist here.
#
# `-E` and the ERR trap below make a bare failing command annotate itself: job
# logs need admin rights over the repository, so an annotation is the only reason
# that reaches whoever is debugging.
set -eEuo pipefail

trap 'rc=$?; printf "%s\n" "::error::ci-migrated-install failed at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" "ci-migrated-install FAILED at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})"' ERR

# The paths default to the image layout; they are overridable so this test can
# also be run by hand (with a throwaway NPM_CONFIG_PREFIX and PI_APP_SEED) without
# touching a real /data — a mistake worth making impossible, since the same
# cleanup deletes a working install if it points at one.
ENTRYPOINT="${ENTRYPOINT:-/usr/local/bin/docker-entrypoint.sh}"
NPM_PREFIX="${NPM_CONFIG_PREFIX:-/data/npm}"
NPM_LIB="${NPM_PREFIX}/lib/node_modules"
NPM_BIN="${NPM_PREFIX}/bin"
HERDR_INSTALL_DIR="${HERDR_INSTALL_DIR:-${HOME}/.local/bin}"
# The checkout is named `<id>-<commit>` (the vendor's own layout), so it is
globbed rather than spelled out — a hardcoded unhashed path silently pointed at
a directory that never exists, and the two assertions below then failed for the
wrong reason.
PLUGIN_DIR="$(ls -d "${HOME}"/.config/herdr/plugins/github/devswha.herdr-web-ui* 2>/dev/null | head -1)"

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
PI_APP_SEED=/nonexistent "${ENTRYPOINT}" true
test -e "${NPM_LIB}/pi-web-ui"
test -e "${NPM_LIB}/@earendil-works/pi-coding-agent"
test -L "${NPM_BIN}/pi-web-ui"
echo "OK: cleanup skipped when the image seed is absent"

# --------------------------------------------------------------------------
# 4. idempotent: a second start with nothing to clean is a no-op
# --------------------------------------------------------------------------
"${ENTRYPOINT}" true
"${ENTRYPOINT}" true
test -d "${NPM_LIB}/some-user-tool"
echo "OK: idempotent"

# --------------------------------------------------------------------------
# 5. seeding never overwrites something that is already there — this is what
#    keeps `herdr update` / `herdr plugin update` from being rolled back by a
#    restart, and what keeps a plugin's state in the volume authoritative
# --------------------------------------------------------------------------
test -x "${HERDR_INSTALL_DIR}/herdr"
printf '#!/bin/sh\necho herdr-updated\n' > "${HERDR_INSTALL_DIR}/herdr.updatetest"
chmod +x "${HERDR_INSTALL_DIR}/herdr.updatetest"
herdr_before="$(cat "${HERDR_INSTALL_DIR}/herdr.updatetest")"
"${ENTRYPOINT}" true
test -f "${HERDR_INSTALL_DIR}/herdr.updatetest"
test "$(cat "${HERDR_INSTALL_DIR}/herdr.updatetest")" = "${herdr_before}"
test -x "${HERDR_INSTALL_DIR}/herdr"
rm -f "${HERDR_INSTALL_DIR}/herdr.updatetest"

# The plugin is the more interesting case: the entrypoint seeds a whole checkout
# with installed dependencies, and must do so only when the volume has none. A
# plugin *update* writes into that checkout, so an unconditional copy would undo
# it on the next start — silently, because the plugin would still boot.
test -f "${PLUGIN_DIR}/plugin/entry.js"
printf 'marker\n' > "${PLUGIN_DIR}/CI-SEED-MARKER"
"${ENTRYPOINT}" true
test -f "${PLUGIN_DIR}/CI-SEED-MARKER"
rm -f "${PLUGIN_DIR}/CI-SEED-MARKER"

# And the registry the entrypoint repairs must keep pointing into the volume, not
# back at the image seed, after a start over an existing install.
node -e '
const fs = require("fs");
const home = process.env.HOME;
const registry = JSON.parse(fs.readFileSync(home + "/.config/herdr/plugins.json", "utf8"));
const entries = Array.isArray(registry) ? registry : Object.values(registry);
for (const p of entries) {
  const root = p.plugin_root || "";
  if (!root.startsWith(home + "/")) { console.error("plugin_root left pointing outside the volume: " + root); process.exit(1); }
  if (!fs.existsSync(p.manifest_path)) { console.error("manifest_path does not exist: " + p.manifest_path); process.exit(1); }
}
console.log("OK: registry paths resolve inside the volume (" + entries.length + " entries)");
'

echo "migrated-install test OK"
