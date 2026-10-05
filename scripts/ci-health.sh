#!/usr/bin/env bash
#
# Regression test for the v0.1.0 outage, run on the CI runner against the built
# image. That outage came from pi-web-ui's host guard, which refused every Host it
# was not told about — including 127.0.0.1 — while fetch() cannot set a Host header
# at all (undici drops it), so the container never looked healthy and
# `docker compose up --wait` gave up while the app was serving fine: "it never came
# online". Collie's guard is narrower (API routes only — see ci-host-guard.sh), but
# the healthcheck still claims an allowed host, so this pins that a boot with a
# strict allow-list reaches `healthy` on its own.
#
# This boots the image in exactly that configuration and requires it to reach
# `healthy` on its own. On failure it prints — and annotates — the container
# logs and docker's own healthcheck probe output, so the reason survives even
# when the raw job log is not available to whoever is debugging.
#
# It also proves the startup path as a whole: the bridge only starts after the
# entrypoint has seeded Collie and herdr's server has become reachable, so a
# healthy container means all of that worked.
#
# `-E` and the ERR trap below cover the failures that never reach fail(): a bare
# `docker exec` assertion under `set -e` would otherwise exit silently, and job
# logs need admin rights over the repository, so the annotation is the only
# reason that reaches whoever is debugging.
set -eEuo pipefail

trap 'rc=$?; echo "::error::ci-health failed at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

NAME=collie-hc
IMAGE=pi-docker:ci

annotate() { while IFS= read -r line; do printf '::error::%s\n' "${line//%/%25}"; done; }

# The *reason* is annotated ahead of the context: GitHub renders only a handful of
# annotations and samples them, so a dump that puts 25 context lines before the
# actual error can arrive with the reason cut off entirely. An ENOENT or a stack
# trace near the end of the log is the whole point of dumping it.
dump_logs() {
  docker logs "${NAME}" 2>&1 | grep -iE 'error|ENOENT|panic|fatal|refused|denied|failed|cannot' | tail -12 | annotate || true
  docker logs "${NAME}" 2>&1 | tail -6 | annotate || true
}

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
  dump_logs
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
  dump_logs
  exit 1
}

docker exec "${NAME}" test -x /data/home/.local/share/collie/current/bin/collie \
  || fail "Collie was not seeded into the volume"
# The bridge only survives startup if COLLIE_PLUGIN_ROOT is Collie's *plugin* root
# — the directory holding package.json and herdr-plugin.toml, i.e. `current`
# inside a binary install and not the install root one level above it. Collie
# trusts an injected value without checking for its marker, so an off-by-one path
# makes readFileSync(<root>/package.json) throw before the bridge ever binds a
# port, and the container reports "unhealthy" with the cause one line below the
# banner. Asserted here so a regression names itself instead of just hanging.
docker exec "${NAME}" test -f /data/home/.local/share/collie/current/package.json \
  || fail "Collie's plugin root is missing package.json"
docker exec "${NAME}" test -f /data/home/.local/share/collie/current/herdr-plugin.toml \
  || fail "Collie's plugin root is missing herdr-plugin.toml — COLLIE_PLUGIN_ROOT cannot be derived from it"
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
