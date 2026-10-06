#!/usr/bin/env bash
#
# Persistence. This is the invariant the whole image exists for: everything the
# agent installs and everything the apps keep must survive a restart *and* a
# container recreate, and the only reason the image seeds herdr and the plugin
# into the volume is so their own updaters (`herdr update`, `herdr plugin update`)
# write somewhere that survives too.
#
# Three things are checked, and the third is the one that regresses silently:
#
#   1. A tool the agent installs into /data/npm is still on PATH and still runs
#      after a restart and after a recreate. PATH has to win over the image
#      prefix for /usr/local (the baked pi CLI), so this also pins the ordering.
#   2. Agent state — pi's config dir, a session file, project files in
#      /workspace — survives, and a skill the *user* placed under
#      ${PI_CODING_AGENT_DIR}/skills is not clobbered by the entrypoint's bundled
#      skill symlinking.
#   3. A changed file inside the seeded apps is NOT overwritten on the next start.
#      This is the "seed, never install" rule: the entrypoint copies only when the
#      destination is missing, so an update landing in the volume must not be
#      rolled back by reopening the container. An entrypoint that unconditionally
#      re-copied from the image would pass (1) and (2) and fail this one, and the
#      visible symptom would be `herdr update` silently reverting on every restart.
#
# `-E` plus the ERR trap: a bare failing command under `set -e` exits silently and
# job logs need admin rights, so the annotation is the only reason that survives.
set -eEuo pipefail

trap 'rc=$?; echo "::error::ci-persistence failed at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

NAME=herdr-web-persist
IMAGE=pi-docker:ci
VOL=data-test-$$
# /workspace is a *second* volume in the real deployment — compose mounts it
# separately from /data — so the test mounts one too. Writing to the container
# layer instead looks identical until a recreate throws it away, which is exactly
# how this test failed the first time it ran.
VOLWS=data-test-ws-$$
TOOL=cowsay

annotate() { while IFS= read -r line; do printf '::error::%s\n' "${line//%/%25}"; done; }

dump_logs() {
  # The job log is uncapped; the annotations panel is not (10 per run, and the
  # error line has to be one of them). So the whole dump goes to stdout and only
  # the lines that carry the reason are annotated.
  {
    echo "===== container log (last 60) ====="
    docker logs "${NAME}" 2>&1 | tail -60
    echo "===== herdr server log (last 30) ====="
    docker exec "${NAME}" tail -n 30 /data/home/.config/herdr/herdr-server.log 2>/dev/null
    echo "===== plugin state dir ====="
    docker exec "${NAME}" ls -la /data/home/.config/herdr-web-ui 2>&1
    echo "===== herdr plugin list ====="
    docker exec "${NAME}" herdr plugin list 2>&1
    echo "===== herdr plugin start (manual attempt) ====="
    docker exec "${NAME}" herdr plugin start devswha.herdr-web-ui 2>&1
    sleep 5
    echo "===== plugin processes after the manual start ====="
    docker exec "${NAME}" ps -eo pid=,args= 2>&1 | grep -E 'managed\.ts|supervisor\.ts'
    echo "===== herdr plugin log ====="
    docker exec "${NAME}" herdr plugin log devswha.herdr-web-ui 2>&1 | tail -30
    echo "===== end of dump ====="
  } 2>&1 | sed 's/^/    /' || true

  # Annotations: only what names the reason. The error itself is emitted by
  # fail() before this, so it is always present.
  docker logs "${NAME}" 2>&1 | grep -E '\[pi-docker\].*(seed|register|repair|start|already|ready|WARNING|error|Error)' | tail -6 | annotate || true
  docker exec "${NAME}" herdr plugin list 2>&1 | tail -3 | annotate || true
  docker exec "${NAME}" herdr plugin start devswha.herdr-web-ui 2>&1 | tail -6 | annotate || true
}

cleanup() {
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker volume rm "${VOL}" >/dev/null 2>&1 || true
  docker volume rm "${VOLWS}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "::error::$1"
  dump_logs
  exit 1
}

# The image's own ENV values are deliberately overridden here to point '^' at the
# volume: if the image ever hardcodes a path instead of reading these, this test
# notices because the state would land outside the volume.
start() {
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker run -d --init --name "${NAME}" \
    -e HOME=/data/home \
    -e PI_CODING_AGENT_DIR=/data/agent \
    -e NPM_CONFIG_PREFIX=/data/npm \
    -e PI_WORKSPACE_DIR=/workspace \
    -e HERDR_WEB_HOST=0.0.0.0 \
    -e HERDR_WEB_PORT=7317 \
    -v "${VOL}:/data" \
    -v "${VOLWS}:/workspace" \
    "${IMAGE}"
}

wait_server() {
  local i
  for i in $(seq 1 60); do
    if docker exec "${NAME}" herdr api snapshot >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  fail "herdr's server did not come up after a (re)start"
}

# herdr's socket answering is NOT the web UI being up: the plugin is started by
# herdr's own startup hook, a moment later. Polling the plugin's own health
# endpoint is the only signal that means what this test claims to check — the
# single-shot probe that used to be here raced the plugin's supervisor and failed
# a stack that was merely still starting.
wait_web() {
  local i
  for i in $(seq 1 30); do
    if docker exec "${NAME}" node -e 'require("http").get({host:"127.0.0.1",port:Number(process.env.PORT||7317),path:"/api/health"},(s)=>{process.exit(s.statusCode===200?0:1)}).on("error",()=>process.exit(1))' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

echo "=== boot 1: fresh volume, install an agent tool and write state ==="
start
wait_server

# A tool the agent would install for itself, into the persisted npm prefix.
docker exec "${NAME}" npm install -g "${TOOL}" >/dev/null 2>&1 \
  || fail "could not install ${TOOL} into ${NPM_CONFIG_PREFIX:-/data/npm}"
docker exec "${NAME}" test -x /data/npm/bin/"${TOOL}" \
  || fail "npm did not create /data/npm/bin/${TOOL}"

# Agent state: pi's config dir, a session file, and a skill the user owns. The
# skill matters because the entrypoint symlinks bundled skills into that same
# directory and must skip any path that already exists.
docker exec "${NAME}" bash -lc '
set -e
mkdir -p /data/agent/skills/my-own-skill
printf "name: my-own-skill\ndescription: user-provided skill\n" > /data/agent/skills/my-own-skill/SKILL.md
mkdir -p /data/agent/sessions
echo "session-marker" > /data/agent/sessions/ci-session.json
echo "workspace-marker" > /workspace/ci-project-file
echo "key-marker" > /data/agent/auth.json
'

# /workspace must be a real mount before anything is written there, or the test
# would be checking the container layer and still pass a restart.
docker exec "${NAME}" mountpoint -q /workspace \
  || fail "/workspace is not a mounted volume in this test (writes would land in the container layer)"

# A change inside the seeded apps, standing in for `herdr update` /
# `herdr plugin update` / editing the plugin env. It must survive.
# The checkout directory carries the installed commit in its name
# (`…-210f619d6b7b`), so it is globbed: the literal name does not exist.
docker exec "${NAME}" bash -lc '
set -e
PDIR="$(ls -d /data/home/.config/herdr/plugins/github/devswha.herdr-web-ui* | head -1)"
test -d "$PDIR"
echo "updated-by-ci" > /data/home/.local/bin/herdr-update-marker
echo "plugin-updated" > "$PDIR/CI-UPDATE-MARKER"
'

# ---------------------------------------------------------------------------
echo "=== restart: container restarts in place ==="
# ---------------------------------------------------------------------------
docker restart "${NAME}" >/dev/null
wait_server

docker exec "${NAME}" bash -lc "command -v ${TOOL} >/dev/null"
docker exec "${NAME}" "${TOOL}" --help >/dev/null 2>&1 || true
docker exec "${NAME}" test -f /data/agent/sessions/ci-session.json
docker exec "${NAME}" test -f /workspace/ci-project-file
docker exec "${NAME}" test -f /data/agent/auth.json
docker exec "${NAME}" test -f /data/agent/skills/my-own-skill/SKILL.md
docker exec "${NAME}" test -f /data/home/.local/bin/herdr-update-marker || fail "a change to the seeded herdr was lost across a restart (the entrypoint re-seeded over it)"
docker exec "${NAME}" bash -lc 'test -f "$(ls -d /data/home/.config/herdr/plugins/github/devswha.herdr-web-ui* | head -1)/CI-UPDATE-MARKER"' || fail "a plugin update was lost across a restart (the entrypoint re-seeded over it)"
# A restart is the gentle case (SIGTERM, no lost state). If the web UI does not
# come back here either, then the trigger is not a hard kill leaving something
# stale — it is that a volume which *already* holds the plugin never gets it
# started, which is a different bug with a different fix.
wait_web || fail "the web UI is not serving after a restart"
echo "restart: ok"

# ---------------------------------------------------------------------------
echo "=== recreate: same volume, brand new container ==="
# ---------------------------------------------------------------------------
# This is the case a plain restart does not cover: everything the image installs
# outside the volume is gone, so anything missing here was never persisted.
start
wait_server

# The tool is not just present on disk, it is on PATH — and PATH must still prefer
# the image for the pi CLI, or a stale volume copy could shadow the tested version.
tool_path="$(docker exec "${NAME}" bash -lc "command -v ${TOOL}" || true)"
[ "${tool_path}" = "/data/npm/bin/${TOOL}" ] \
  || fail "${TOOL} is not on PATH after a recreate (got: ${tool_path:-nothing})"
docker exec "${NAME}" "${TOOL}" --help >/dev/null 2>&1 || true
docker exec "${NAME}" bash -lc 'test "$(command -v pi)" = "/usr/local/bin/pi"' \
  || fail "the pi CLI is no longer resolved to the image copy after a recreate"

docker exec "${NAME}" test -f /data/agent/sessions/ci-session.json \
  || fail "pi session state did not survive a recreate"
docker exec "${NAME}" test -f /data/agent/auth.json \
  || fail "agent credentials did not survive a recreate"
docker exec "${NAME}" test -f /workspace/ci-project-file \
  || fail "workspace files did not survive a recreate"
docker exec "${NAME}" test -f /data/agent/skills/my-own-skill/SKILL.md \
  || fail "a user-provided skill was clobbered by the bundled skill symlinking"
docker exec "${NAME}" test -L /data/agent/skills/persistent-tool-install \
  || fail "a bundled skill is no longer symlinked after a recreate"
docker exec "${NAME}" test -f /data/home/.local/bin/herdr-update-marker \
  || fail "a change to the seeded herdr was lost across a recreate (seeded over the volume)"
docker exec "${NAME}" bash -lc 'test -f "$(ls -d /data/home/.config/herdr/plugins/github/devswha.herdr-web-ui* | head -1)/CI-UPDATE-MARKER"' \
  || fail "a plugin update was lost across a recreate (seeded over the volume)"

# And the container is still a working stack afterwards, not merely a volume with
# files in it: the plugin must have been repaired to the volume and be serving.
wait_web || fail "the web UI is not serving after a recreate (waited 60s)"

echo "persistence OK"
