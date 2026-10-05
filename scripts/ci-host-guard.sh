#!/usr/bin/env bash
#
# Pins the contract the Dockerfile healthcheck and the README depend on: with
# COLLIE_PUBLIC_HOSTS set, Collie's *API routes* answer only the allowed host,
# and the health endpoint answers regardless.
#
# Measured against Collie 1.16.2 (see the probe matrix below) — the guard is on
# the API routes that expose or mutate state, NOT on every route:
#
#   Host                    GET /api/health    GET /api/config
#   pi.notato.xyz           200                200
#   stranger.example        200                403 host not allowed
#
# So the refusal half is asserted on /api/config. Asserting it on /api/health —
# as this test first did — claims a contract Collie never offered and fails
# against a perfectly healthy container.
#
# The allowed-host half is the load-bearing one for the healthcheck. The refused
# half is asserted as "not 200" rather than a specific code, and prints the code
# it actually got, so a change in *how* Collie refuses stays visible in the log
# instead of surfacing as an unexplained failure.
#
# `/` and unknown paths fall through to the static SPA shell for any Host, which
# is why nothing here asserts on them: there is no guard to pin.
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
GUARDED=/api/config
HEALTH=/api/health

annotate() { while IFS= read -r line; do printf '::error::%s\n' "${line//%/%25}"; done; }

# Reason first, then context — see the note in ci-health.sh: annotations are
# capped and sampled, so the error line must not sit behind 25 context lines.
dump_logs() {
  docker logs "${NAME}" 2>&1 | grep -iE 'error|ENOENT|panic|fatal|refused|denied|failed|cannot' | tail -12 | annotate || true
  docker logs "${NAME}" 2>&1 | tail -6 | annotate || true
}

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --init --name "${NAME}" \
  -e COLLIE_PUBLIC_HOSTS="${ALLOWED}" \
  -e COLLIE_ALLOWED_ORIGINS="https://${ALLOWED}" \
  "${IMAGE}"

# $1 = Host header, $2 = "200" to require it, "not200" to require anything else,
# "any" to just log it, $3 = path (default /api/health).
probe() {
  docker exec "${NAME}" node -e "
    const req = require('http').get(
      { host: '127.0.0.1', port: Number(process.env.COLLIE_PORT || 8787), path: '${3:-${HEALTH}}', headers: { Host: '$1' } },
      (s) => {
        console.log('$1 -> ' + s.statusCode + '  ${3:-${HEALTH}}');
        const want = '$2';
        if (want === 'any') process.exit(0);
        process.exit(want === '200' ? (s.statusCode === 200 ? 0 : 1) : (s.statusCode === 200 ? 1 : 0));
      }
    );
    req.on('error', (e) => { console.error('$1 -> ' + e.message); process.exit(1); });
    req.setTimeout(3000, () => { req.destroy(); process.exit(1); });
  "
}

ready=""
for _ in $(seq 1 150); do
  if probe "${ALLOWED}" 200 "${HEALTH}" 2>/dev/null; then ready=yes; break; fi
  running=$(docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null || echo false)
  if [ "${running}" = "false" ]; then break; fi
  sleep 2
done

if [ -z "${ready}" ]; then
  echo "::error::the allowed host never got a 200 from ${HEALTH}"
  docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}}' "${NAME}" 2>/dev/null | annotate || true
  dump_logs
  exit 1
fi

# 1. the allowed host is served, on the health endpoint and on a guarded route
probe "${ALLOWED}" 200 "${HEALTH}"
probe "${ALLOWED}" 200 "${GUARDED}"

# 2. a Host that was not allowed is refused on the API — this is what makes a
#    by-IP client render the shell and then fail to talk to the API
if ! probe "${FOREIGN}" not200 "${GUARDED}"; then
  echo "::error::Collie served ${GUARDED} to a Host that is not in COLLIE_PUBLIC_HOSTS: ${FOREIGN}"
  dump_logs
  exit 1
fi

# 3. the health endpoint is deliberately exempt, so the probe above tested the
#    guard and not the route. Not asserted as a requirement: if Collie ever
#    tightens this, the healthcheck still claims an allowed host and keeps
#    working — it would just stop being belt-and-braces.
probe "${FOREIGN}" any "${HEALTH}"

echo "host guard OK"
