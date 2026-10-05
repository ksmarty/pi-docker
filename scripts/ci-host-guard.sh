#!/usr/bin/env bash
#
# Pins the contract the healthcheck depends on: with COLLIE_PUBLIC_HOSTS set, the
# allowed host is served and an unknown Host is not. If Collie ever changes that,
# the healthcheck in the Dockerfile has to change with it, and this is where that
# gets caught. Runs on the CI runner against the built image.
#
# The allowed-host half is the load-bearing one. The refused half is asserted as
# "not 200" rather than a specific code, and prints the code it actually got, so
# a change in *how* Collie refuses is visible in the log instead of being
# reported as an unexplained failure.
#
# `-E` and the ERR trap below make a bare failing command annotate itself with
# the line and the command: job logs need admin rights over the repository, so an
# annotation is the only reason that reaches whoever is debugging.
set -eEuo pipefail

trap 'rc=$?; echo "::error::ci-host-guard failed at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

NAME=collie-hg
IMAGE=pi-docker:ci
ALLOWED=pi.notato.xyz
FOREIGN=not-the-allowed-host.example

annotate() { while IFS= read -r line; do printf '::error::%s\n' "${line//%/%25}"; done; }

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --init --name "${NAME}" \
  -e COLLIE_PUBLIC_HOSTS="${ALLOWED}" \
  -e COLLIE_ALLOWED_ORIGINS="https://${ALLOWED}" \
  "${IMAGE}"

# $1 = Host header, $2 = "200" to require it, "not200" to require anything else.
probe() {
  docker exec "${NAME}" node -e "
    const req = require('http').get(
      { host: '127.0.0.1', port: Number(process.env.COLLIE_PORT || 8787), path: '/api/health', headers: { Host: '$1' } },
      (s) => {
        console.log('$1 -> ' + s.statusCode);
        const want = '$2';
        process.exit(want === '200' ? (s.statusCode === 200 ? 0 : 1) : (s.statusCode === 200 ? 1 : 0));
      }
    );
    req.on('error', (e) => { console.error('$1 -> ' + e.message); process.exit(1); });
    req.setTimeout(3000, () => { req.destroy(); process.exit(1); });
  "
}

ready=""
for _ in $(seq 1 150); do
  if probe "${ALLOWED}" 200 2>/dev/null; then ready=yes; break; fi
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
probe "${ALLOWED}" 200

# 2. a Host that was not allowed is refused — this is what makes a bare
#    `curl http://<server-ip>:8787` fail, so that it does so is the contract
if ! probe "${FOREIGN}" not200; then
  echo "::error::Collie served a Host that is not in COLLIE_PUBLIC_HOSTS: ${FOREIGN}"
  echo "::error::if Collie no longer validates Host, the healthcheck's Host header and the README both assume it does"
  docker logs "${NAME}" 2>&1 | tail -15 | annotate || true
  exit 1
fi

echo "host guard OK"
