#!/usr/bin/env bash
#
# Smoke test that runs INSIDE the built image. CI pipes this file into the
# container with `bash -lc "$(cat scripts/ci-smoke.sh)"` (see
# .github/workflows/ci.yml) and passes EXPECT_NODE.
#
# The image's own ENTRYPOINT still runs first (the passed command only replaces
# CMD), so everything the entrypoint prepares — the persisted directories, the
# seeded herdr, the plugin registration, the profile.d file, the skill symlinks —
# is in place by the time this script executes. That is deliberate: this is a test
# of the real startup path, not of a bare image.
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

# The reason has to reach *stdout* as a plain line, not only as an annotation: the
# runner lifts `::error::` lines out of the log into the annotations panel, and a
# failure that existed only as an annotation was invisible from here — the panel
# showed nothing but GitHub's own "Process completed with exit code 1".
trap 'rc=$?; printf "%s\n" "::error::ci-smoke failed at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" "ci-smoke FAILED at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})"' ERR

# Assertions go through this so the log says what was being checked when it
# stopped. Bare `test` lines are silent by design, and that is how a wrong path in
# this very file cost a full CI round trip to find.
check() {
  local label="$1"; shift
  if "$@"; then
    echo "  ok   ${label}"
  else
    echo "  FAIL ${label} (${*})"
    exit 1
  fi
}

echo "node       : $(node -v)"
echo "npm        : $(npm -v)"
echo "bun        : $(bun --version 2>&1 | tail -1)"
echo "pi CLI     : $(pi --version 2>&1 | tail -1)"
echo "herdr      : $(herdr --version 2>&1 | tail -1)"
echo "entrypoint : $(command -v docker-entrypoint.sh)"

# The base image must be the Node line CI asked for. A matrix typo, or an ARG
# that stopped being forwarded into the Dockerfile, lands here.
test "$(node -p 'process.versions.node.split(".")[0]')" = "${EXPECT_NODE}"

# The entrypoint's state preparation: without these, the panes herdr shows and
# the agent both lose their persisted paths.
check "/etc/profile.d/pi-paths.sh is written" test -f /etc/profile.d/pi-paths.sh
check "/data/npm exists" test -d /data/npm
check "/data/agent exists" test -d /data/agent
check "/workspace exists" test -d /workspace

# The pi CLI must be the image's copy, not something from the persisted volume:
# /usr/local/bin has to win over /data/npm/bin or a stale copy can shadow the
# version this image was built and tested with. Same for the toolchain, which is
# a feature of the runtime and not a build-time nicety.
check "pi resolves to the image copy" test "$(command -v pi)" = "/usr/local/bin/pi"
check "bun resolves to the image copy" test "$(command -v bun)" = "/usr/local/bin/bun"
pi --version >/dev/null
bun --version >/dev/null

# ---------------------------------------------------------------------------
# herdr: seeded into the volume, and the *volume* copy is what runs
# ---------------------------------------------------------------------------
# herdr lives in the volume because that is the only place its own updater can
# keep working (`herdr update`): an update there survives a restart *and* a
# container recreate. The image's copy under /opt/pi-docker/seed is only the seed
# for an empty volume, and reinstating it over the volume copy on every start
# would silently roll back `herdr update` — so the seed is asserted to exist and
# the runtime copy is asserted to be the one on PATH.
check "the image's herdr seed exists" test -x /opt/pi-docker/seed/bin/herdr
check "herdr was seeded into the volume" test -x "${HOME}/.local/bin/herdr"
check "the volume's herdr is the one on PATH" test "$(command -v herdr)" = "${HOME}/.local/bin/herdr"
herdr --version >/dev/null
# herdr's server is the multiplexer the UI mirrors; the entrypoint starts it
# before the plugin, so by now the socket API must answer. `herdr api snapshot`
# goes over the socket and exits non-zero with server_not_running until the
# server is really listening. `herdr session list --json` would NOT test this: it
# is a local command that exits 0 with `"running": false` when nothing is up, so
# it passes against a container whose server has died.
#
# The probe's own output is annotated when it fails: "exit 1" on this line was
# exactly how a real regression arrived (the server was only started under the
# default `serve`, so a container running this script had none), and the reason
# was one grep away the whole time.
if ! snapshot="$(herdr api snapshot 2>&1)"; then
  echo "::error::herdr's socket API is not reachable: ${snapshot}"
  echo "::error::herdr-server.log tail: $(tail -n 6 "${HOME}/.config/herdr/herdr-server.log" 2>/dev/null | tr '\n' ' ')"
  echo "::error::herdr processes: $(ps -eo pid=,args= 2>/dev/null | grep -c '[h]erdr') running"
  exit 1
fi

# ---------------------------------------------------------------------------
# The web UI plugin: installed into the volume, registered, enabled, configured
# ---------------------------------------------------------------------------
# Nothing about the plugin may come from the network at start: an empty volume has
# to boot with the UI ready. That means the checkout and its installed
# dependencies are in the volume (seeded by the entrypoint, so `herdr plugin
# update` persists), the registry entry points at the volume, and the plugin is
# enabled there.
PLUGIN_DIR="$(ls -d "${HOME}"/.config/herdr/plugins/github/devswha.herdr-web-ui* 2>/dev/null | head -1)"
# herdr appends the installed commit to the checkout directory
# (`…/devswha.herdr-web-ui-210f619d6b7b`), so the path is globbed instead of
# written out: the literal path is what this file asserted first, and it does not
# exist. The registry block below pins the exact paths herdr recorded.
check "the plugin checkout was seeded into the volume" test -n "${PLUGIN_DIR}"
check "the checkout is a directory" test -d "${PLUGIN_DIR}"
check "the checkout is not a symlink into the image" test ! -L "${PLUGIN_DIR}"
check "package.json is present" test -f "${PLUGIN_DIR}/package.json"
check "herdr-plugin.toml is present" test -f "${PLUGIN_DIR}/herdr-plugin.toml"
check "the plugin's dependencies are installed" test -d "${PLUGIN_DIR}/node_modules"
check "the plugin's server directory is present" test -d "${PLUGIN_DIR}/server"
# The manifest's startup entry — the file herdr actually executes. A plugin whose
# manifest points at a missing script registers and then does nothing.
check "the manifest's startup script exists" test -f "${PLUGIN_DIR}/scripts/plugin.ts"
check "the plugin registry exists" test -f "${HOME}/.config/herdr/plugins.json"
check "the registry directory is not a symlink" test ! -L "${HOME}/.config/herdr/plugins"

# The registry records three absolute paths per entry. The build writes them
# pointing into the seed and the entrypoint repairs them to the volume, so after
# startup every one of them must live under ${HOME} — the failure this catches is
# a plugin that is "installed" but whose manifest_path still points into the image
# (or worse, at a build host path that does not exist in the container).
node -e '
const fs = require("fs");
const home = process.env.HOME;
let registry;
try { registry = JSON.parse(fs.readFileSync(home + "/.config/herdr/plugins.json", "utf8")); }
catch (e) { console.error("plugins.json unreadable: " + e.message); process.exit(1); }
const entries = Array.isArray(registry) ? registry : Object.values(registry);
const ui = entries.find((p) => p && (p.plugin_id === "devswha.herdr-web-ui" || (p.plugin_root || "").includes("herdr-web-ui")));
if (!ui) { console.error("the web UI plugin is not in the registry: " + JSON.stringify(registry)); process.exit(1); }
if (ui.enabled !== true) { console.error("the web UI plugin is not enabled (enabled=" + ui.enabled + ")"); process.exit(1); }
for (const key of ["plugin_root", "manifest_path"]) {
  const value = ui[key];
  if (!value || !value.startsWith(home + "/")) {
    console.error(key + " does not point into the volume: " + value); process.exit(1);
  }
  if (!fs.existsSync(value)) { console.error(key + " does not exist: " + value); process.exit(1); }
}
const managed = ui.source && ui.source.managed_path;
if (!managed || !managed.startsWith(home + "/")) {
  console.error("source.managed_path does not point into the volume: " + managed); process.exit(1);
}
console.log("plugin registered from the volume: " + ui.plugin_id + " @" + ui.plugin_root + " enabled=" + ui.enabled);
'

# The plugin's config is the file that decides what the UI binds to, and it is
# read from the volume rather than from the container environment — so if this
# file is missing, the environment is silently ignored. Its two non-secret keys
# are asserted here; the health test proves the port is actually served.
check "herdr's config.toml is in the volume" test -f "${HOME}/.config/herdr/config.toml"
check "the plugin's env file is in the volume" test -f "${HOME}/.config/herdr/plugins/config/devswha.herdr-web-ui/env"
check "the env file sets HOST" grep -q '^HOST=' "${HOME}/.config/herdr/plugins/config/devswha.herdr-web-ui/env"
check "the env file sets PORT" grep -q '^PORT=' "${HOME}/.config/herdr/plugins/config/devswha.herdr-web-ui/env"

# ---------------------------------------------------------------------------
# The toolchain and the persistent install paths the bundled skill documents
# ---------------------------------------------------------------------------
# The skill tells the agent it can build native modules and `pip install --user`,
# so both have to be true in the image rather than assumed. ripgrep is a hard
# prerequisite of the plugin's own runtime, so it is part of "the image works".
check "make, g++, python3, rg, git, curl are on PATH" command -v make g++ python3 rg git curl
curl --version >/dev/null
rg --version >/dev/null
python3 -m pip --version
# `/data/npm` is where the agent's own tools go; the image's packages must not be
# there or a stale copy shadows the baked one.
check "no migrated pi-web-ui in /data/npm" test ! -e "${NPM_CONFIG_PREFIX}/lib/node_modules/pi-web-ui"
check "no migrated pi CLI in /data/npm" test ! -e "${NPM_CONFIG_PREFIX}/lib/node_modules/@earendil-works/pi-coding-agent"
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
check "the hand-written skill is in the image" test -f /opt/pi-docker/skills/persistent-tool-install/SKILL.md
check "it is linked into the agent dir" test -L /data/agent/skills/persistent-tool-install
check "the generated herdr skill is in the image" test -f /opt/pi-docker/skills/herdr/SKILL.md
check "it is linked into the agent dir" test -L /data/agent/skills/herdr
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
