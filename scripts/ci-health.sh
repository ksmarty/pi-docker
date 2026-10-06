#!/usr/bin/env bash
#
# Regression test for the outage that started all of this: "I just tried it and it
# never came online. The logs were unhelpful."
#
# The container *was* serving. What failed was the healthcheck, which probed the
# web UI with a Host header the app refused, so docker reported `unhealthy`
# forever and `docker compose up --wait` gave up while the app was fine. The
# lesson is therefore not "add a host header" (the current plugin has no host
# guard at all — see ci-web-ui.sh, which pins that): it is that a container whose
# liveness probe lies about the app is indistinguishable from a broken app.
#
# So this boots the image the way a user does — fresh, no volume, no environment
# beyond what the compose file sets — and requires it to reach `healthy` on its
# own. On failure it prints and annotates the container logs *and* docker's own
# healthcheck probe output, because an `unhealthy` with no reason in the log was
# the entire complaint.
#
# It also proves the startup path as a whole: the health endpoint only answers
# once the plugin is up and linked to the herdr server, and the plugin is only
# started after the entrypoint has seeded herdr, installed the plugin into the
# volume and repaired its registry paths.
#
# `-E` and the ERR trap cover the failures that never reach fail(): a bare
# `docker exec` assertion under `set -e` would otherwise exit silently, and job
# logs need admin rights over the repository, so the annotation is the only
# reason that reaches whoever is debugging.
set -eEuo pipefail

trap 'rc=$?; printf "%s\n" "::error::ci-health failed at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" "ci-health FAILED at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})"' ERR

NAME=herdr-web-hc
IMAGE=pi-docker:ci

annotate() { while IFS= read -r line; do printf '::error::%s\n' "${line//%/%25}"; done; }

# The *reason* is annotated ahead of the context: GitHub renders only a handful of
# annotations and samples them, so a dump that puts 25 context lines before the
# actual error can arrive with the reason cut off entirely. An ENOENT or a stack
# trace near the end of the log is the whole point of dumping it.
dump_logs() {
  docker logs "${NAME}" 2>&1 | grep -iE 'error|ENOENT|panic|fatal|refused|denied|failed|cannot|EADDRINUSE' | tail -12 | annotate || true
  docker logs "${NAME}" 2>&1 | tail -6 | annotate || true
}

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# No volume on purpose: an empty volume is what a first run looks like, and that
# is the path that has to work (the entrypoint seeds herdr and installs the
# plugin into it). PORT is left at its default so a wrong default is caught.
docker run -d --init --name "${NAME}" \
  -e HOME=/data/home \
  -e PI_CODING_AGENT_DIR=/data/agent \
  -e NPM_CONFIG_PREFIX=/data/npm \
  -e HERDR_WEB_HOST=0.0.0.0 \
  -e HERDR_WEB_PORT=7317 \
  "${IMAGE}"

# Docker's probe only runs every 15s, so poll for a while: with 5 retries a verdict
# can lag the app coming up by a minute or more, and a cold first boot on an empty
# volume seeds herdr, installs the plugin's dependencies and starts the server
# before anything binds.
status=unknown
for _ in $(seq 1 150); do
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${NAME}" 2>/dev/null || echo gone)
  case "${status}" in
    healthy | gone | no-healthcheck) break ;;
  esac
  sleep 2
done

echo "health status: ${status}"
echo "--- container logs ---"
docker logs "${NAME}" 2>&1 | tail -40 || true
echo "--- healthcheck probes (exit code + output) ---"
docker inspect -f '{{range .State.Health.Log}}exit={{.ExitCode}} out={{.Output}}{{end}}' "${NAME}" 2>/dev/null || true

if [ "${status}" != "healthy" ]; then
  echo "::error::container never became healthy (status=${status})"
  docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${NAME}" 2>/dev/null | annotate || true
  docker inspect -f '{{range .State.Health.Log}}health probe exit={{.ExitCode}} out={{.Output}}{{end}}' "${NAME}" 2>/dev/null | annotate || true
  dump_logs
  exit 1
fi

# ---------------------------------------------------------------------------
# What "healthy" should mean, checked from inside the container
# ---------------------------------------------------------------------------
# A 200 from /api/health could in principle come from something other than the
# stack we ship, so the parts it depends on are asserted directly. These fail
# loudly instead of annotating, because at this point the container is up and the
# log above is already readable.
fail() {
  echo "::error::$1"
  dump_logs
  exit 1
}

# The banner is the operator's only view of what the container resolved to, and
# the previous image's failure was invisible precisely because the banner claimed
# one thing while the app did another. So the *effective* bind — the value from the
# plugin's own env file, which is what the UI actually listens on — has to appear.
banner="$(docker logs "${NAME}" 2>&1 || true)"
grep -q 'web ui bind: 0.0.0.0:7317' <<<"${banner}" \
  || fail "the banner does not report the effective bind (got: $(grep -o 'web ui bind:.*' <<<"${banner}" || echo 'no bind line'))"

# herdr's server is the multiplexer the UI mirrors: without it the UI has no
# panes and /api/health reports ok:false, since the plugin reports its socket
# link in the same body.
docker exec "${NAME}" herdr api snapshot >/dev/null \
  || fail "herdr's server is not reachable inside the container"
docker exec "${NAME}" test -x /data/home/.local/bin/herdr \
  || fail "herdr was not seeded into the volume"
docker exec "${NAME}" test ! -L /data/home/.local/share/herdr \
  || fail "the seeded herdr install is a symlink into the image — self-updates would be ephemeral"

# The plugin must be installed *into the volume* and started from there. A plugin
# served out of the image would boot fine and then lose every update on restart.
# herdr names the checkout directory after the installed commit
# (`…/devswha.herdr-web-ui-210f619d6b7b`), so it is resolved rather than written
# out: the literal path does not exist, and neither does `plugin/entry.js` — the
# server herdr runs is `server/managed.ts`.
docker exec "${NAME}" bash -lc 'test -d "$(ls -d /data/home/.config/herdr/plugins/github/devswha.herdr-web-ui* | head -1)"' \
  || fail "the web UI plugin was not seeded into the volume"
procs="$(docker exec "${NAME}" ps -eo pid=,args= || true)"
echo "${procs}"
# Captured into a variable on purpose: `ps | grep -q` would fail under
# `set -o pipefail` as soon as grep exits on the first match and ps gets SIGPIPE.
grep -q 'server/managed\.ts' <<<"${procs}" \
  || fail "no plugin process is running in the container"

# The ui must be serving from that volume copy, not from /opt/pi-docker/seed: the
# health body names the plugin's own root.
health_body="$(docker exec "${NAME}" node -e '
const port = Number(process.env.PORT || 7317);
require("http").get({ host: "127.0.0.1", port, path: "/api/health" }, (s) => {
  let b = ""; s.on("data", (c) => (b += c)); s.on("end", () => process.stdout.write(b));
}).on("error", (e) => { console.error(e.message); process.exit(1); });
' 2>&1)" || fail "/api/health could not be read from inside the container: ${health_body}"
echo "health body: ${health_body}"
grep -q '"ok":true' <<<"${health_body}" || fail "/api/health does not report ok:true: ${health_body}"

# A command run inside a *live* container must leave the server alone. The
# entrypoint runs for `docker exec` too, and a second `herdr server` does not fail
# politely — it takes the socket over from the running one, and the plugin's
# supervisor is a child of the server that just lost it, so the web UI stops
# answering (measured on herdr 0.9.3; the persistence test caught it). The
# plugin's pid is the marker, because a server restart re-spawns it under a new
# one.
plugin_pid() { docker exec "${NAME}" ps -eo pid=,args= 2>/dev/null | awk '/server\/managed\.ts/ { print $1; exit }'; }
pid_before="$(plugin_pid || true)"
docker exec "${NAME}" herdr plugin list >/dev/null 2>&1 \
  || fail "herdr plugin list failed inside the running container"
sleep 3
pid_after="$(plugin_pid || true)"
[ -n "${pid_before}" ] || fail "the web UI's process was not running before the extra command"
[ "${pid_before}" = "${pid_after}" ] \
  || fail "a command run inside the container restarted herdr's server (web UI pid ${pid_before} -> ${pid_after:-gone})"
docker exec "${NAME}" node -e '
const port = Number(process.env.PORT || 7317);
require("http").get({ host: "127.0.0.1", port, path: "/api/health" }, (s) => process.exit(s.statusCode === 200 ? 0 : 1))
  .on("error", () => process.exit(1));
' || fail "the web UI stopped answering after a command was run in the container"

echo "healthcheck OK"
