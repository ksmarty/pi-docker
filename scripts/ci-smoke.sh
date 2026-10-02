#!/usr/bin/env bash
#
# Smoke test that runs INSIDE the built image. CI pipes this file into the
# container with `bash -lc "$(cat scripts/ci-smoke.sh)"` (see
# .github/workflows/ci.yml) and passes EXPECT_NODE.
#
# It deliberately lives in a file instead of inline in the workflow: an inline
# script has to survive being nested inside `docker run ... bash -lc '<script>'`,
# and a single quote in the script then closes that outer quoting — which
# silently truncates it and hands the tail to docker as extra arguments. That is
# not a hypothetical: it is exactly how the first version of this test failed
# with a bare "exit code 2" and no explanation.
set -euo pipefail

echo "node       : $(node -v)"
echo "npm        : $(npm -v)"
echo "pi-web-ui  : $(pi-web-ui --version 2>&1 | tail -1)"
echo "pi CLI     : $(pi --version 2>&1 | tail -1)"
echo "entrypoint : $(command -v docker-entrypoint.sh || echo 'not on PATH (expected)')"

# The entrypoint's state preparation: without these, the web UI's terminal tab
# and the agent both lose their persisted paths.
test -f /etc/profile.d/pi-paths.sh
test -d /data/npm
test -d /data/agent

# The base image must be the Node line CI asked for. A matrix typo, or an ARG
# that stopped being forwarded into the Dockerfile, lands here.
test "$(node -p 'process.versions.node.split(".")[0]')" = "${EXPECT_NODE}"

# The app must be the image's copy, not something from the persisted volume:
# /usr/local/bin has to win over /data/npm/bin or a stale app can shadow the
# version this image was built and tested with.
test "$(command -v pi-web-ui)" = "/usr/local/bin/pi-web-ui"
test "$(command -v pi)" = "/usr/local/bin/pi"

pi-web-ui --version >/dev/null
pi --version >/dev/null

# node-pty has no Linux prebuild and is compiled from source at build time, so
# prove it still loads under the Node the base image ships. A version bump is
# exactly the change that breaks this, and it breaks at runtime, not at build.
node -e "
const p = require.resolve('node-pty', { paths: ['/usr/local/lib/node_modules/pi-web-ui'] });
require(p);
console.log('node-pty loaded from ' + p);
"

# The bundled skill documents `curl -fsSL ...` recipes (rustup, uv, bun, go), so
# curl has to be in the image rather than assumed.
curl --version >/dev/null

# `pip install --user` is the persistent Python path the same skill documents, so
# the PEP 668 marker must be gone.
python3 -m pip --version
if ls /usr/lib/python3*/EXTERNALLY-MANAGED >/dev/null 2>&1; then
  echo "PEP 668 marker still present — pip install --user would refuse" >&2
  exit 1
fi

# Skills are symlinked into the agent dir at startup and must be discoverable by
# pi's own loader — a file sitting in the image is not proof the agent sees it.
test -f /opt/pi-docker/skills/persistent-tool-install/SKILL.md
test -L /data/agent/skills/persistent-tool-install
node -e '
import("/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/skills.js").then((m) => {
  const r = m.loadSkills({ cwd: "/workspace", agentDir: "/data/agent", skillPaths: [], includeDefaults: true });
  const names = r.skills.map((s) => s.name);
  if (!names.includes("persistent-tool-install")) {
    console.error("skill not discovered: " + names + " diagnostics: " + JSON.stringify(r.diagnostics));
    process.exit(1);
  }
  console.log("skill discovered: " + names.join(","));
}).catch((e) => { console.error(e); process.exit(1); });
'

echo "smoke test OK"
