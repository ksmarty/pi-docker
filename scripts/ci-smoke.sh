#!/usr/bin/env bash
#
# Smoke test that runs INSIDE the built image. CI pipes this file into the
# container with `bash -lc "$(cat scripts/ci-smoke.sh)"` (see
# .github/workflows/ci.yml) and passes EXPECT_NODE.
#
# The image's own ENTRYPOINT still runs first (the passed command only replaces
# CMD), so everything the entrypoint prepares — the persisted directories, the
# seeded apps, the profile.d file, the skill symlinks — is in place by the time
# this script executes. That is deliberate: this is a test of the real startup
# path, not of a bare image.
#
# It deliberately lives in a file instead of inline in the workflow: an inline
# script has to survive being nested inside `docker run ... bash -lc '<script>'`,
# and a single quote in the script then closes that outer quoting — which
# silently truncates it and hands the tail to docker as extra arguments. That is
# not a hypothetical: it is exactly how the first version of this test failed
# with a bare "exit code 2" and no explanation.
#
# `-E` plus the ERR trap is what makes a *bare* failing command explain itself: it
# re-emits the line and the command as an annotation. That matters because
# GitHub will not hand out job logs without admin rights over the repository, so
# the annotation is the only failure channel that survives.
set -eEuo pipefail

trap 'rc=$?; echo "::error::ci-smoke failed at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

echo "node       : $(node -v)"
echo "npm        : $(npm -v)"
echo "pi CLI     : $(pi --version 2>&1 | tail -1)"
echo "collie     : $(collie --version 2>&1 | tail -1 || true)"
echo "herdr      : $(herdr --version 2>&1 | tail -1)"
echo "entrypoint : $(command -v docker-entrypoint.sh || echo 'not on PATH (expected)')"

# The base image must be the Node line CI asked for. A matrix typo, or an ARG
# that stopped being forwarded into the Dockerfile, lands here.
test "$(node -p 'process.versions.node.split(".")[0]')" = "${EXPECT_NODE}"

# The entrypoint's state preparation: without these, the panes Collie shows and
# the agent both lose their persisted paths.
test -f /etc/profile.d/pi-paths.sh
test -d /data/npm
test -d /data/agent
test -d /workspace

# The pi CLI must be the image's copy, not something from the persisted volume:
# /usr/local/bin has to win over /data/npm/bin or a stale copy can shadow the
# version this image was built and tested with.
test "$(command -v pi)" = "/usr/local/bin/pi"
test "$(command -v collie)" = "/usr/local/bin/collie"

pi --version >/dev/null
herdr --version >/dev/null
collie --help >/dev/null

# ---------------------------------------------------------------------------
# The seeded apps
# ---------------------------------------------------------------------------
# Herdr and Collie live in the volume, because that is the only place their own
# updaters can keep working (`herdr update`, `collie update`): an update there
# survives a restart *and* a container recreate. The image's copy is the seed for
# an empty volume.
test -x "${HOME}/.local/share/collie/current/bin/collie"
test -x "${HOME}/.local/bin/herdr"
test -f "${HOME}/.config/herdr/config.toml"
test -x /opt/pi-docker/seed/bin/herdr
test -x /opt/pi-docker/seed/collie/current/bin/collie

# It has to be a real directory, not a symlink back into the image: a symlinked
# install root would make every self-update ephemeral, which is the exact failure
# this layout exists to prevent.
test ! -L "${HOME}/.local/share/collie"
# What has to be true is that the binary that actually runs lives in the volume,
# so `collie update` writes somewhere that survives. /usr/local/bin/collie is
# deliberately NOT a symlink into the volume — it is a stable shim that execs
# "$COLLIE_DIR/current/bin/collie" at runtime (see the Dockerfile) — so resolving
# the command name proves nothing about where the install is. Resolve the install
# root instead. (Asserting the shim itself was a symlink is how this test first
# failed, with nothing in the job log to say why.)
resolved="$(readlink -f "${HOME}/.local/share/collie/current/bin/collie")"
case "${resolved}" in
  "${HOME}"/.local/share/collie/*)
    echo "collie runs from the volume: ${resolved}"
    ;;
  *)
    echo "collie does not run from the persisted volume: ${resolved}" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# The toolchain and the persistent install paths the bundled skill documents
# ---------------------------------------------------------------------------
# The skill tells the agent it can build native modules and `pip install --user`,
# so both have to be true in the image rather than assumed.
command -v make g++ python3 >/dev/null
curl --version >/dev/null
python3 -m pip --version
if ls /usr/lib/python3*/EXTERNALLY-MANAGED >/dev/null 2>&1; then
  echo "PEP 668 marker still present — pip install --user would refuse" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Skills
# ---------------------------------------------------------------------------
# Skills are symlinked into the agent dir at startup and must be discoverable by
# pi's own loader — a file sitting in the image is not proof the agent sees it.
# `persistent-tool-install` is hand-written in this repo; `herdr` is generated at
# build time from the installed binary (`herdr --skill`), so this also proves the
# vendor's skill reached the agent with its frontmatter intact.
test -f /opt/pi-docker/skills/persistent-tool-install/SKILL.md
test -L /data/agent/skills/persistent-tool-install
test -f /opt/pi-docker/skills/herdr/SKILL.md
test -L /data/agent/skills/herdr
node -e '
import("/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/skills.js").then((m) => {
  const r = m.loadSkills({ cwd: "/workspace", agentDir: "/data/agent", skillPaths: [], includeDefaults: true });
  const names = r.skills.map((s) => s.name);
  const missing = ["persistent-tool-install", "herdr"].filter((n) => !names.includes(n));
  if (missing.length) {
    console.error("skills not discovered: " + missing + " (got: " + names + ") diagnostics: " + JSON.stringify(r.diagnostics));
    process.exit(1);
  }
  console.log("skills discovered: " + names.join(","));
}).catch((e) => { console.error(e); process.exit(1); });
'

echo "smoke test OK"
