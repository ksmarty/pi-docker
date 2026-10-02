#!/usr/bin/env bash
#
# Pins the contract the healthcheck depends on: with PI_WEB_ALLOW_HOSTS set, the
# allowed host gets a 200 and anything else gets 403. If pi-web-ui ever changes
# that behaviour the healthcheck in the Dockerfile has to change with it, and
# this is where that gets caught. Runs on the CI runner against the built image.
set -euo pipefail

NAME=pi-hg
IMAGE=pi-docker:ci
ALLOWED=pi.notato.xyz

annotate() { while IFS= read -r line; do printf '::error::%s\n' "${line//%/%25}"; done; }

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --init --name "${NAME}" \
  -e PI_WEB_ALLOW_HOSTS="${ALLOWED}" \
  "${IMAGE}"

# Wait for the app to answer at all, giving up early if the container dies.
probe_body() {
  # $1 = Host header, $2 = expected status
  docker exec "${NAME}" node -e "
    const req = require('http').get(
      { host: '127.0.0.1', port: 8787, path: '/api/health', headers: { Host: '$1' } },
      (s) => { console.log('$1 -> ' + s.statusCode); process.exit(s.statusCode === $2 ? 0 : 1); }
    );
    req.on('error', (e) => { console.error('$1 -> ' + e.message); process.exit(1); });
    req.setTimeout(3000, () => { req.destroy(); process.exit(1); });
  "
}

ready=""
for _ in $(seq 1 150); do
  if probe_body "${ALLOWED}" 200 2>/dev/null; then ready=yes; break; fi
  running=$(docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null || echo false)
  if [ "${running}" = "false" ]; then break; fi
  sleep 2
done

if [ -z "${ready}" ]; then
  echo "::error::the allowed host never got a 200 from /api/health"
  docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}}' "${NAME}" 2>/dev/null | annotate || true
  docker logs "${NAME}" 2>&1 | tail -25 | annotate || true
  exit 1
fi

# 1. the allowed host is served
probe_body "${ALLOWED}" 200
# 2. a Host that was not allowed is refused — this is what makes the healthcheck
#    and `curl http://<ip>:8787` fail, so the status code is part of the contract
probe_body "127.0.0.1:8787" 403

echo "host guard OK"
