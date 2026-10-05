#!/usr/bin/env bash
#
# Regression test for the v0.1.0 outage, run on the CI runner against the built
# image. Collie refuses every Host it was not told about, and with
# COLLIE_PUBLIC_HOSTS set that includes 127.0.0.1 — so a plain probe to
# 127.0.0.1 (which cannot even set a Host header through fetch(), because undici
# drops it) fails, the container never looks healthy, and `docker compose up
# --wait` gives up while the app is serving fine: "it never came online".
#
# This boots the image in exactly that configuration and requires it to reach
# `healthy` on its own. On failure it prints — and annotates — the container
# logs and docker's own healthcheck probe output, so the reason survives even
# when the raw job log is not available to whoever is debugging.
#
# It also proves the startup path as a whole: the bridge only starts after the
# entrypoint has seeded Collie and herdr's server has become reachable, so a
# healthy container means all of that worked.
set -euo pipefail

NAME=collie-hc
IMAGE=pi-docker:ci

annotate() { while IFS= read -r line; do printf '::error::%s\n' "${line//%/%25}"; done; }

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --init --name "${NAME}" \
  -e COLLIE_PUBLIC_HOSTS=pi.notato.xyz \
  -e COLLIE_ALLOWED_ORIGINS=https://pi.notato.xyz \
  "${IMAGE}"

# Docker's probe only runs every 15s, so poll for a while: with 5 retries a
# verdict can lag the app coming up by a minute or more, and a cold first boot
# on an empty volume seeds Collie, starts herdr and only then binds.
status=unknown
for _ in $(seq 1 150); do
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${NAME}" 2>/dev/null || echo gone)
  case "${status}" in
    healthy | gone | no-healthcheck) break ;;
  esac
  sleep 2
done

echo "health status: ${status}"
echo "--- docker logs ---"
docker logs "${NAME}" 2>&1 | tail -40 || true
echo "--- healthcheck probes (exit code + output) ---"
docker inspect -f '{{range .State.Health.Log}}exit={{.ExitCode}} out={{.Output}}{{end}}' "${NAME}" 2>/dev/null || true

if [ "${status}" != "healthy" ]; then
  echo "::error::container never became healthy (status=${status})"
  docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${NAME}" 2>/dev/null | annotate || true
  docker inspect -f '{{range .State.Health.Log}}health probe exit={{.ExitCode}} out={{.Output}}{{end}}' "${NAME}" 2>/dev/null | annotate || true
  docker logs "${NAME}" 2>&1 | tail -25 | annotate || true
  exit 1
fi

# ---------------------------------------------------------------------------
# What "healthy" should mean, checked from inside the container
# ---------------------------------------------------------------------------
# A 200 from /api/health could in principle come from something other than the
# stack we ship, so the parts it depends on are asserted directly. These fail
# loudly instead of annotating, because at this point the container is up and
# the log above is already readable.
fail() {
  echo "::error::$1"
  docker logs "${NAME}" 2>&1 | tail -25 | annotate || true
  exit 1
}

docker exec "${NAME}" test -x /data/home/.local/share/collie/current/bin/collie \
  || fail "Collie was not seeded into the volume"
docker exec "${NAME}" test -x /data/home/.local/bin/herdr \
  || fail "herdr was not seeded into the volume"
docker exec "${NAME}" test ! -L /data/home/.local/share/collie \
  || fail "Collie's install root is a symlink into the image — self-updates would be ephemeral"
# herdr's server is the multiplexer Collie mirrors: without it the bridge has no
# panes at all, so it is part of what "the container works" means.
# `herdr api snapshot` goes over the socket API and exits non-zero with
# server_not_running until the server is really listening. `herdr session list
# --json` would NOT test this: it is a local command that exits 0 with
# `"running": false` when nothing is up, so it passes against a container whose
# server has died.
docker exec "${NAME}" herdr api snapshot >/dev/null \
  || fail "herdr's server is not reachable inside the container"
# The bridge must be running as the container's main child (PID 1 is tini, from
# init: true), not a background service that happened to leave something
# listening. Captured into a variable on purpose: `ps | grep -q` would fail under
# `set -o pipefail` as soon as grep exits on the first match and ps gets SIGPIPE.
bridge_procs="$(docker exec "${NAME}" ps -eo pid=,args= || true)"
echo "${bridge_procs}"
grep -q _exec-bridge <<<"${bridge_procs}" \
  || fail "the Collie bridge is not running in the container"

echo "healthcheck OK"
