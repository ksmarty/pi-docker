#!/usr/bin/env bash
#
# The served HTTP contract of the web UI plugin, pinned from outside the container.
#
# This replaces the old ci-host-guard.sh, which pinned Collie's host allow-list.
# The current plugin has no host allow-list, and the earlier lesson still stands
# in a new form: a probe must test something the app actually offers. The old
# image's probe sent a Host header the app refused; asserting *any* header
# behaviour here would be the mirror-image mistake — claiming a contract nobody
# offered. So every number below was measured against the shipped plugin first
# (plugin 0.3.50, README + live probing) and the test only pins those.
#
# Measured:
#
#   GET /                       -> 200 HTML (the PWA shell; it asks to pair rather
#                                  than closing the connection)
#   GET /api/health             -> 200 {"ok":true,"herdr":{...},"auth":{...},
#                                       "web_ui":{"boot_id":...,"revision":...}}
#   GET /api/health (foreign Host) -> 200, identical body — no host guard
#   GET /health                 -> the SPA's index.html, NOT a health endpoint;
#                                  probed only to pin that it is not JSON, because
#                                  "probe /health" is the obvious wrong guess
#   GET /api/health with a token set -> still 200, unauthenticated (the plugin
#                                  documents health as exempt), which is what makes
#                                  the image's HEALTHCHECK work for a locked-down
#                                  deployment
#
# `-E` and the ERR trap: a bare failing command under `set -e` exits silently, and
# job logs need admin rights, so the annotation is the only reason that reaches
# whoever is debugging.
set -eEuo pipefail

trap 'rc=$?; printf "%s\n" "::error::ci-web-ui failed at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" "ci-web-ui FAILED at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})"' ERR

NAME=herdr-web-ui-probe
IMAGE=pi-docker:ci
PORT=7317

annotate() { while IFS= read -r line; do printf '::error::%s\n' "${line//%/%25}"; done; }

dump_logs() {
  docker logs "${NAME}" 2>&1 | grep -iE 'error|ENOENT|panic|fatal|refused|denied|failed|cannot|EADDRINUSE' | tail -12 | annotate || true
  docker logs "${NAME}" 2>&1 | tail -6 | annotate || true
}

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() {
  echo "::error::$1"
  dump_logs
  exit 1
}

# A token is set on purpose: it is the strictest configuration a user can deploy,
# and the health probe has to keep working under it — a locked-down install whose
# container reports `unhealthy` is the exact failure this whole test file exists
# to prevent. The token never reaches the probe: /api/health is exempt, which is
# asserted below rather than assumed.
docker run -d --init --name "${NAME}" \
  -e HOME=/data/home \
  -e PI_CODING_AGENT_DIR=/data/agent \
  -e NPM_CONFIG_PREFIX=/data/npm \
  -e HERDR_WEB_HOST=0.0.0.0 \
  -e HERDR_WEB_PORT="${PORT}" \
  -e HERDR_WEB_TOKEN=ci-token-not-a-real-secret \
  "${IMAGE}"

# probe <host-header-or-empty> <path> -> writes STATUS=/TYPE=/BODY= records
# Each call runs inside the container on loopback, with an explicit Host when one
# is given, so "does a foreign Host matter?" is answered rather than assumed.
#
# The header line is built in a variable instead of with `${host:+...}`: bash ends
# that expansion at the first `}`, which lands inside the JS object literal — the
# result is a stray `;}` on its own line and a SyntaxError from node. (Found by
# running this function against a fake server before trusting CI to.)
probe() {
  local host="$1" path="$2" inner header_line=""
  if [ -n "${host}" ]; then
    header_line="opts.headers = { Host: '${host}' };"
  fi
  inner="$(cat <<EOF
const http = require('http');
const opts = { host: '127.0.0.1', port: ${PORT}, path: '${path}' };
${header_line}
const r = http.get(opts, (s) => {
  let b = '';
  s.on('data', (c) => (b += c));
  s.on('end', () => {
    process.stdout.write('STATUS=' + s.statusCode + '\n');
    process.stdout.write('TYPE=' + (s.headers['content-type'] || '') + '\n');
    process.stdout.write('BODY=' + b.slice(0, 400) + '\n');
  });
});
r.on('error', (e) => { process.stdout.write('ERROR=' + e.message + '\n'); });
r.setTimeout(5000, () => { r.destroy(); process.stdout.write('ERROR=timeout\n'); });
EOF
)"
  docker exec -i "${NAME}" node -e "${inner}" 2>&1 || true
}

status_of() { sed -n 's/^STATUS=//p' <<<"$1"; }
body_of() { sed -n 's/^BODY=//p' <<<"$1"; }
type_of() { sed -n 's/^TYPE=//p' <<<"$1"; }

# Wait on the port, not on `docker inspect`: this test is about the HTTP surface,
# so it should not spend a healthcheck interval waiting for docker's own verdict.
ready=0
for _ in $(seq 1 90); do
  if docker exec "${NAME}" node -e "
require('http').get({host:'127.0.0.1',port:${PORT},path:'/api/health'},(s)=>{process.exit(s.statusCode===200?0:1)}).on('error',()=>process.exit(1));
" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
[ "${ready}" = "1" ] || {
  # Report what the port actually said. "never answered" on its own hides the
  # difference between a plugin that is still booting, one that answered 503
  # because its link to the herdr server died, and one that is not listening at
  # all — and a CI failure that does not say which is a CI failure someone has to
  # reproduce by hand.
  observed="$(probe "" "/api/health" | tr '\n' ' ' | cut -c1-300)"
  fail "the web UI never answered 200 on port ${PORT} (observed: ${observed:-nothing at all})"
}

echo "=== GET / ==="
shell="$(probe "" "/")"; echo "${shell}"
[ "$(status_of "${shell}")" = "200" ] \
  || fail "the PWA shell is not served at / (got: ${shell})"
grep -qi 'text/html' <<<"$(type_of "${shell}")" \
  || fail "/ did not answer HTML (got: $(type_of "${shell}"))"

echo "=== GET /api/health (no Host header) ==="
health="$(probe "" "/api/health")"; echo "${health}"
[ "$(status_of "${health}")" = "200" ] \
  || fail "/api/health is not 200 (got: ${health})"
hb="$(body_of "${health}")"
# The vendor's own liveness field, plus the two halves it proves: `herdr` reports
# the server the plugin is talking to, and `web_ui.boot_id` exists only if the UI
# itself booted. This is why the image's HEALTHCHECK asserts ok:true rather than
# any status code: a plugin that is up but whose socket link died must not look
# healthy.
grep -q '"ok":true' <<<"${hb}" || fail "/api/health does not report ok:true: ${hb}"
grep -q '"herdr"' <<<"${hb}" || fail "/api/health does not report the herdr link: ${hb}"
grep -q '"web_ui"' <<<"${hb}" || fail "/api/health does not report the web_ui boot state: ${hb}"

echo "=== GET /api/health (foreign Host header) ==="
foreign="$(probe "not-the-real-host.invalid" "/api/health")"; echo "${foreign}"
[ "$(status_of "${foreign}")" = "200" ] \
  || fail "a foreign Host header changed /api/health (got: ${foreign}) — if this plugin ever grows a host allow-list, the image's healthcheck must start sending an allowed Host (this is the Collie outage, exactly)"
grep -q '"ok":true' <<<"$(body_of "${foreign}")" \
  || fail "the body behind a foreign Host is not the health body: ${foreign}"

echo "=== GET /health (no /api prefix) ==="
noapi="$(probe "" "/health")"; echo "${noapi}"
grep -qi 'json' <<<"$(type_of "${noapi}")" && fail "/health answers JSON — the probe contract moved and the image's HEALTHCHECK should follow it: ${noapi}"
grep -qi 'text/html' <<<"$(type_of "${noapi}")" \
  || fail "/health is neither JSON nor the SPA shell, so the surface is unclear: ${noapi}"
echo "note: /health is the SPA shell, not an endpoint — do not probe it"

echo "web ui HTTP contract OK"
