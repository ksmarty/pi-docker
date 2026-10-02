#!/usr/bin/env bash
#
# Regression test for the v0.1.0 outage, run on the CI runner against the built
# image. pi-web-ui refuses every Host it was not told about, and with
# PI_WEB_ALLOW_HOSTS set that includes 127.0.0.1 — so the old healthcheck (a
# plain fetch to 127.0.0.1, which cannot even set a Host header) returned 403
# forever. `docker compose up --wait` never saw a healthy container while the
# app was serving fine and the logs looked normal: "it never came online".
#
# This boots the image in exactly that configuration and requires it to reach
# `healthy` on its own. On failure it prints — and annotates — the container
# logs and docker's own healthcheck probe output, so the reason survives even
# when the raw job log is not available to whoever is debugging.
set -euo pipefail

NAME=pi-hc
IMAGE=pi-docker:ci

annotate() { while IFS= read -r line; do printf '::error::%s\n' "${line//%/%25}"; done; }

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --init --name "${NAME}" \
  -e PI_WEB_ALLOW_HOSTS=pi.notato.xyz \
  -e PI_WEB_ALLOW_ORIGINS=https://pi.notato.xyz \
  "${IMAGE}"

# Docker's probe only runs every 30s, so poll for a while: with only 3 retries
# a verdict can lag the app coming up by a minute or more, and a cold first boot
# on an empty volume has to sync the plugin catalog before it listens.
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

echo "healthcheck OK"
