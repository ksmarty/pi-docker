#!/usr/bin/env bash
#
# Entrypoint for pi-docker.
#
# The image already contains the pi CLI, Bun, a seed copy of Herdr and a *built*
# copy of the herdr web ui plugin, so this script does NOT download anything. It:
#
#   1. (re)creates the persisted directories inside the mounted volume,
#   2. seeds Herdr, its config and the web UI plugin into the volume on first
#      start, never over an existing install, so an empty volume boots offline
#      and a self-updated install is never clobbered,
#   3. writes the plugin's settings file (bind address, port, optional token),
#   4. cleans up the app a pre-Dockerfile compose left in ${NPM_CONFIG_PREFIX},
#   5. makes sure login shells (the panes the web UI shows) inherit the same PATH,
#   6. on "serve": starts the headless herdr server, waits for its socket, reports
#      what the web UI resolved to, and then supervises the server in the
#      foreground. Herdr's own startup hook is what brings the web UI up.
#
# A missing/empty volume after `docker compose down -v` is a non-event: the stack
# comes up healthy immediately, with no network access required.
set -euo pipefail

# ---------------------------------------------------------------------------
# Persisted locations
# ---------------------------------------------------------------------------
# Every default keeps the container self-contained under /data, and every one can
# be overridden from the compose file. Herdr's and the plugin's own defaults
# already live under $HOME, which is the volume — these are explicit so the
# layout is readable from here, not from two other projects' docs.
export HOME="${HOME:-/data/home}"
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-/data/npm}"
export PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-/data/agent}"
export PI_WORKSPACE_DIR="${PI_WORKSPACE_DIR:-/workspace}"
APP_SEED="${PI_APP_SEED:-/opt/pi-docker/seed}"

# herdr: a single binary in ~/.local/bin plus state under ~/.herdr and config
# under ~/.config/herdr. All of it under $HOME = the volume, so `herdr update`
# writes somewhere that survives a restart.
export HERDR_INSTALL_DIR="${HERDR_INSTALL_DIR:-${HOME}/.local/bin}"
export HERDR_CONFIG_PATH="${HERDR_CONFIG_PATH:-${HOME}/.config/herdr/config.toml}"
HERDR_CONFIG_DIR="$(dirname "${HERDR_CONFIG_PATH}")"
HERDR_PLUGINS_DIR="${HERDR_CONFIG_DIR}/plugins"
HERDR_REGISTRY="${HERDR_CONFIG_DIR}/plugins.json"

# The web UI plugin. Its id is <owner>.<repo>, which is also the directory name
# herdr gives it and the key it uses in every command below.
HERDR_WEB_PLUGIN_ID="devswha.herdr-web-ui"
HERDR_WEB_PLUGIN_DIR="${HERDR_PLUGINS_DIR}/config/${HERDR_WEB_PLUGIN_ID}"
HERDR_WEB_ENV_FILE="${HERDR_WEB_PLUGIN_DIR}/env"

# These two are *this image's* knobs, not the plugin's: the plugin reads its
# settings from HERDR_WEB_ENV_FILE and never from the container environment
# ("plugin settings do not come from the user's shell"), so they are written into
# that file below. 0.0.0.0 because a reverse proxy in a sibling container cannot
# reach this container's 127.0.0.1; the plugin's own default is loopback.
export HERDR_WEB_HOST="${HERDR_WEB_HOST:-0.0.0.0}"
export HERDR_WEB_PORT="${HERDR_WEB_PORT:-7317}"
# Pairing, push keys, device subscriptions and update builds live here. Default
# is the plugin's own ($HOME/.config/herdr-web-ui = the volume), and it is only
# set explicitly so the path is visible in the banner and in profile.d: losing
# this directory means re-pairing every device.
export HERDR_WEB_STATE_DIR="${HERDR_WEB_STATE_DIR:-${HOME}/.config/herdr-web-ui}"

# Canonical search order, prepended to whatever PATH the container arrived with.
# /usr/local (the image's own prefix, which is where Bun and the pi CLI live)
# comes BEFORE ${NPM_CONFIG_PREFIX}/bin and ~/.bun/bin on purpose: those two are
# the agent's own install targets, and a stale copy there must not shadow the
# version the image was built with.
PI_PATH_PREFIX="${PI_CODING_AGENT_DIR}/bin:/usr/local/sbin:/usr/local/bin:${NPM_CONFIG_PREFIX}/bin:${HOME}/.local/bin:${HOME}/.cargo/bin:${HOME}/go/bin:${HOME}/.bun/bin"
export PATH="${PI_PATH_PREFIX}:${PATH}"

# `:-` defaults matter: an unset var would otherwise expand to "" and
# `mkdir -p ""` aborts the whole script under `set -e`.
mkdir -p "${HOME}" "${NPM_CONFIG_PREFIX}" "${PI_CODING_AGENT_DIR}" "${PI_WORKSPACE_DIR}" \
         "${HERDR_INSTALL_DIR}" "${HOME}/.herdr" "${HERDR_CONFIG_DIR}" \
         "${HERDR_PLUGINS_DIR}" "${HERDR_WEB_PLUGIN_DIR}" "${HERDR_WEB_STATE_DIR}"

# ---------------------------------------------------------------------------
# Seeding the apps from the image
# ---------------------------------------------------------------------------
# The image carries a seed copy of both apps; the volume is where they actually
# live, because that is the only place their own updaters can keep working.
# Seeding is a local copy — no network, no apt, no npm, no build — and it happens
# only when the destination is missing, so:
#
#   * an empty volume gets a working app in seconds,
#   * `herdr update` and the web UI's Settings -> Updates stay updated across
#     restarts AND across a container recreate (`docker compose down && up`)
#     instead of being silently rolled back to the image's version,
#   * an image rebuild cannot clobber an install the user has updated.
#
# To get back to the image's version, remove the install and restart:
#   rm -rf /data/home/.local/bin/herdr
#   rm -rf /data/home/.config/herdr/plugins /data/home/.config/herdr/plugins.json
# ---------------------------------------------------------------------------
if [ ! -x "${HERDR_INSTALL_DIR}/herdr" ] && [ -x "${APP_SEED}/bin/herdr" ]; then
  echo "[pi-docker] seeding herdr into ${HERDR_INSTALL_DIR} (first start)"
  install -m 0755 "${APP_SEED}/bin/herdr" "${HERDR_INSTALL_DIR}/herdr"
fi

# herdr's first-run setup has nobody to answer it in a headless container, so the
# image ships a minimal config with onboarding off. Only ever seeded when absent:
# ~/.config/herdr/config.toml is yours after that.
if [ ! -e "${HERDR_CONFIG_PATH}" ] && [ -f "${APP_SEED}/herdr/config.toml" ]; then
  mkdir -p "${HERDR_CONFIG_DIR}"
  cp "${APP_SEED}/herdr/config.toml" "${HERDR_CONFIG_PATH}"
  echo "[pi-docker] seeded ${HERDR_CONFIG_PATH} (edit it freely; it is never overwritten)"
fi

# ---------------------------------------------------------------------------
# Seeding the web UI plugin
# ---------------------------------------------------------------------------
# Same idea as herdr itself, with one extra step: a plugin is a *checkout* plus a
# registry entry, and both have to end up in the volume.
#
#   * `plugins/github/<id>-<hash>/` is the checkout, built at image-build time
#     (bun install + bun run build). It is copied only when that exact directory
#     is absent, so a version the user updated in place is never replaced by the
#     image's older one.
#   * `plugins.json` is herdr's registry. Herdr finds the checkout by scanning the
#     plugins directory, so the UI runs even with no registry at all — measured —
#     but the registry is what makes the plugin show up in `herdr plugin list`,
#     answer `herdr plugin config-dir`, and appear in Settings -> Updates. So it
#     is merged in, never overwritten: a user who installed other plugins keeps
#     their entries.
#
# The trap this avoids: the registry records *three* absolute paths per entry —
# measured as `manifest_path`, `plugin_root` and `source.managed_path`, all with
# the value `<checkout>/[herdr-plugin.toml]` from a key named `plugin_id`. The
# image's copy of the registry was written at build time, so those paths point at
# the build's staging HOME, which does not exist in your container. Copied
# verbatim, everything still *starts* — herdr finds the checkout by scanning the
# plugins directory next to the registry — but anything that follows a recorded
# path (a reinstall, an update, `herdr plugin list` reporting the tree) aims at a
# path from the build host, and a "successful" update would land where nothing
# reads it. So each recorded path is repaired to the volume whenever the one on
# disk does not exist (and left alone when it does, so a plugin you installed or
# linked yourself keeps pointing where you put it).
# ---------------------------------------------------------------------------
if [ -d "${APP_SEED}/home/.config/herdr/plugins" ]; then
  seed_plugins_dir="${APP_SEED}/home/.config/herdr/plugins"
  seed_registry="${APP_SEED}/home/.config/herdr/plugins.json"

  # The checkout. Copy each seed tree that is not already in the volume.
  if [ -d "${seed_plugins_dir}/github" ]; then
    mkdir -p "${HERDR_PLUGINS_DIR}/github"
    for seed_tree in "${seed_plugins_dir}/github"/*/; do
      [ -d "${seed_tree}" ] || continue
      tree_name="$(basename "${seed_tree}")"
      if [ ! -e "${HERDR_PLUGINS_DIR}/github/${tree_name}" ]; then
        echo "[pi-docker] seeding web UI plugin into ${HERDR_PLUGINS_DIR}/github/${tree_name} (first start)"
        cp -a "${seed_tree}" "${HERDR_PLUGINS_DIR}/github/${tree_name}"
      fi
    done
  fi

  if [ -s "${seed_registry}" ] && command -v jq >/dev/null 2>&1; then
    # Where the checkout actually is in the volume. herdr names the directory
    # <plugin-id>-<hash-of-the-resolved-commit>, so the seed is the source of
    # truth for the name and the registry is only patched to agree with it.
    live_tree="$(ls -d "${HERDR_PLUGINS_DIR}/github/${HERDR_WEB_PLUGIN_ID}"-* 2>/dev/null | head -n1 || true)"
    [ -n "${live_tree}" ] || live_tree="$(ls -d "${HERDR_PLUGINS_DIR}/github/${HERDR_WEB_PLUGIN_ID}" 2>/dev/null | head -n1 || true)"

    [ -s "${HERDR_REGISTRY}" ] || printf '[]\n' > "${HERDR_REGISTRY}"
    recorded_path="$(jq -r --arg id "${HERDR_WEB_PLUGIN_ID}" \
      '.[] | select(.plugin_id == $id) | .plugin_root // .source.managed_path' \
      "${HERDR_REGISTRY}" 2>/dev/null | head -n1 || true)"

    if [ -n "${live_tree}" ]; then
      if [ -n "${recorded_path}" ] && [ ! -e "${recorded_path}" ]; then
        echo "[pi-docker] repairing the plugin registry: ${recorded_path} -> ${live_tree}"
        jq --arg id "${HERDR_WEB_PLUGIN_ID}" --arg root "${live_tree}" \
           --arg manifest "${live_tree}/herdr-plugin.toml" \
           'map(if .plugin_id == $id
                then .plugin_root = $root | .manifest_path = $manifest | .source.managed_path = $root
                else . end)' \
           "${HERDR_REGISTRY}" > "${HERDR_REGISTRY}.tmp"
        if [ -s "${HERDR_REGISTRY}.tmp" ]; then
          mv "${HERDR_REGISTRY}.tmp" "${HERDR_REGISTRY}"
        else
          echo "[pi-docker] WARNING: could not repair the plugin registry; leaving it untouched" >&2
          rm -f "${HERDR_REGISTRY}.tmp"
        fi
      elif [ -z "${recorded_path}" ]; then
        echo "[pi-docker] registering the web UI plugin (first start)"
        # The seed's own entry, with its build-time paths corrected to the
        # volume, appended only if no entry for this plugin exists yet. Every
        # other entry in the volume's registry is preserved.
        # `-n` matters: this program takes *all* of its data from --slurpfile and
        # reads no input, and jq without -n and without stdin input prints nothing
        # at all (exit 0). In a container stdin is /dev/null, so omitting it
        # silently empties the registry — and the check below then refuses to
        # install the empty result over the real one.
        jq -n --slurpfile seed "${seed_registry}" --slurpfile vol "${HERDR_REGISTRY}" \
           --arg id "${HERDR_WEB_PLUGIN_ID}" --arg root "${live_tree}" \
           --arg manifest "${live_tree}/herdr-plugin.toml" \
           '($vol[0] // []) as $have
            | ($seed[0] | map(select(.plugin_id == $id)
                 | .plugin_root = $root | .manifest_path = $manifest | .source.managed_path = $root)) as $want
            | $have + ($want | map(select(.plugin_id as $i | ($have | map(.plugin_id) | index($i)) | not)))' \
           > "${HERDR_REGISTRY}.tmp"
        if [ -s "${HERDR_REGISTRY}.tmp" ]; then
          mv "${HERDR_REGISTRY}.tmp" "${HERDR_REGISTRY}"
        else
          echo "[pi-docker] WARNING: could not register the plugin (jq produced no output); leaving the registry untouched" >&2
          rm -f "${HERDR_REGISTRY}.tmp"
        fi
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# The plugin's settings file
# ---------------------------------------------------------------------------
# `herdr plugin config-dir <id>` prints this directory; the file is named `env`
# (no dot) and holds KEY=value lines. Herdr's own plugin docs use `.env`, and a
# checkout from 0.3.25 on reads both with `.env` winning — this image writes
# `env` because it is the name every version reads.
#
# Appended, never rewritten: the vendor documents this file as the user's way to
# configure the plugin, so a HOST/PORT/token the user put there wins, and keys
# the image manages are only added when absent. The effective values are printed
# in the banner, so a file that disagrees with the compose file is visible rather
# than mysterious.
#
# The token is deliberately NOT generated. The vendor's rule for a proxied
# deployment is "set HERDR_WEB_TOKEN", and this image lets you do exactly that
# from your compose file; with no token the plugin authenticates by identity
# (pairing, see README), which is the default this deployment ships with. If a
# token *is* passed, it is written here and never printed.
if [ -n "${HERDR_WEB_PLUGIN_ID}" ]; then
  mkdir -p "${HERDR_WEB_PLUGIN_DIR}"
  touch "${HERDR_WEB_ENV_FILE}"
  if ! grep -qE '^[[:space:]]*HOST=' "${HERDR_WEB_ENV_FILE}"; then
    printf 'HOST=%s\n' "${HERDR_WEB_HOST}" >> "${HERDR_WEB_ENV_FILE}"
  fi
  if ! grep -qE '^[[:space:]]*PORT=' "${HERDR_WEB_ENV_FILE}"; then
    printf 'PORT=%s\n' "${HERDR_WEB_PORT}" >> "${HERDR_WEB_ENV_FILE}"
  fi
  if [ -n "${HERDR_WEB_TOKEN:-}" ] && ! grep -qE '^[[:space:]]*HERDR_WEB_TOKEN=' "${HERDR_WEB_ENV_FILE}"; then
    printf 'HERDR_WEB_TOKEN=%s\n' "${HERDR_WEB_TOKEN}" >> "${HERDR_WEB_ENV_FILE}"
  fi
  # 600 either way: the file is the only place a token would live, and the
  # vendor is explicit that it must not be readable or logged.
  chmod 600 "${HERDR_WEB_ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# Migrated-install cleanup
# ---------------------------------------------------------------------------
# A container built from the pre-Dockerfile compose installed the old web UI and
# the pi CLI into ${NPM_CONFIG_PREFIX} — i.e. into the persisted volume. The
# image owns both now, and leaving the copies behind is worse than dead weight: a
# stale web UI in the volume would keep an outdated server around, and pi
# resolves its packages from the newest copy it finds. Removing them here makes
# the image the single source of truth on an upgrade, without anyone remembering
# a manual step.
#
# Only those two packages are touched. /data/npm is where the agent's own
# `npm install -g <tool>` calls land, so it is never wiped — and a real file the
# user put at ${NPM_CONFIG_PREFIX}/bin/<name> is left alone (only dangling
# symlinks are collected). Idempotent: a second start finds nothing to do.
#
# Guard: this only runs when the image's own herdr seed is really there, and the
# npm prefix is a real path. Running this script outside the image — a host
# shell, or a container that shares the volume — therefore cannot delete the only
# working install on the box. (That is not theoretical: running an earlier
# version of this script against a live pre-Dockerfile container deleted the
# running app's own files.)
# ---------------------------------------------------------------------------
if [ -x "${APP_SEED}/bin/herdr" ] &&
   [ -n "${NPM_CONFIG_PREFIX}" ] && [ "${NPM_CONFIG_PREFIX}" != "/" ]; then
  NPM_LIB="${NPM_CONFIG_PREFIX}/lib/node_modules"
  for pkg in pi-web-ui @earendil-works/pi-coding-agent; do
    if [ -e "${NPM_LIB}/${pkg}" ]; then
      echo "[pi-docker] removing stale ${pkg} from ${NPM_LIB} (the image provides it now)"
      rm -rf "${NPM_LIB:?}/${pkg}"
    fi
  done
  # An emptied scope dir would otherwise linger as a confusing empty parent.
  rmdir "${NPM_LIB}/@earendil-works" 2>/dev/null || true
  for bin in pi-web-ui pi; do
    link="${NPM_CONFIG_PREFIX}/bin/${bin}"
    if [ -L "${link}" ] && [ ! -e "${link}" ]; then
      echo "[pi-docker] removing dangling ${link}"
      rm -f "${link}"
    fi
  done
fi

# Expose the image's bundled agent skills to pi. They are symlinked, not copied:
# the image stays the single source of truth (an image rebuild updates them) and
# the persisted agent dir holds no duplicate. pi's loader follows symlinked
# directories. Each link is created only when nothing is there, so a skill the
# user replaced with their own real directory is left alone.
SKILLS_SRC=/opt/pi-docker/skills
if [ -d "${SKILLS_SRC}" ]; then
  mkdir -p "${PI_CODING_AGENT_DIR}/skills"
  for skill_dir in "${SKILLS_SRC}"/*/; do
    [ -d "${skill_dir}" ] || continue
    skill_name=$(basename "${skill_dir}")
    skill_link="${PI_CODING_AGENT_DIR}/skills/${skill_name}"
    if [ ! -e "${skill_link}" ] && [ ! -L "${skill_link}" ]; then
      ln -s "${skill_dir%/}" "${skill_link}"
    fi
  done
fi

# The container ENV only covers the main process. The panes the web UI shows and
# anything else started as a login shell read this instead, so `pi`, `herdr`,
# `bun` and the rest resolve in there too. Skipped when unprivileged.
if [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
  cat > /etc/profile.d/pi-paths.sh <<EOF
export HOME="${HOME}"
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX}"
export PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR}"
export PI_WORKSPACE_DIR="${PI_WORKSPACE_DIR}"
export HERDR_INSTALL_DIR="${HERDR_INSTALL_DIR}"
export HERDR_CONFIG_PATH="${HERDR_CONFIG_PATH}"
export HERDR_WEB_STATE_DIR="${HERDR_WEB_STATE_DIR}"
export PATH="${PI_PATH_PREFIX}:\$PATH"
EOF
fi

# ---------------------------------------------------------------------------
# What this container actually resolved to
# ---------------------------------------------------------------------------
# The original report of this image failing was "it never came online, the logs
# were unhelpful" — the cause was a healthcheck the app was refusing while the
# app itself was fine. Everything that could make the UI unreachable-in-fact
# while looking fine is therefore printed on every start: the binaries that were
# found, the effective bind, whether a token is set, and whether the plugin is
# actually registered and enabled.
# ---------------------------------------------------------------------------
# The plugin reads HOST/PORT from its own env file, *not* from the container
# environment, and the file wins whenever both are set. So that file — not this
# process's environment — is what the UI really binds to. It is resolved here,
# before the banner, because the readiness check below must probe the same port
# the app actually listens on; printing the compose value while the file says
# something else is exactly the "the log says one thing, the app does another"
# failure that made the previous outage unreadable.
eff_host="${HERDR_WEB_HOST}"
eff_port="${HERDR_WEB_PORT}"
if [ -f "${HERDR_WEB_ENV_FILE}" ]; then
  if read_val="$(sed -n 's/^[[:space:]]*HOST[[:space:]]*=[[:space:]]*//p' "${HERDR_WEB_ENV_FILE}" | tail -n1)" && [ -n "${read_val}" ]; then
    eff_host="${read_val}"
  fi
  if read_val="$(sed -n 's/^[[:space:]]*PORT[[:space:]]*=[[:space:]]*//p' "${HERDR_WEB_ENV_FILE}" | tail -n1)" && [ -n "${read_val}" ]; then
    eff_port="${read_val}"
  fi
fi

if [ "${PI_QUIET:-0}" != "1" ]; then
  echo "[pi-docker] herdr      : ${HERDR_INSTALL_DIR}/herdr $([ -x "${HERDR_INSTALL_DIR}/herdr" ] && herdr --version 2>/dev/null | head -n1 || echo '(NOT FOUND)')"
  echo "[pi-docker] bun        : $(command -v bun 2>/dev/null || echo 'NOT FOUND') $(bun --version 2>/dev/null || true)"
  echo "[pi-docker] pi CLI     : $(command -v pi 2>/dev/null || echo 'NOT FOUND')"
  echo "[pi-docker] node       : $(command -v node 2>/dev/null || echo 'NOT FOUND') $(node --version 2>/dev/null || true)"
  echo "[pi-docker] data       : home ${HOME}  agent ${PI_CODING_AGENT_DIR}  workspace ${PI_WORKSPACE_DIR}"
  echo "[pi-docker] web ui bind: ${eff_host}:${eff_port}  (state: ${HERDR_WEB_STATE_DIR})"
  if [ "${eff_port}" != "${HERDR_WEB_PORT}" ]; then
    echo "[pi-docker] note       : ${HERDR_WEB_ENV_FILE} sets PORT=${eff_port}, so the UI binds there and not on HERDR_WEB_PORT=${HERDR_WEB_PORT}"
  fi
  if [ -f "${HERDR_WEB_ENV_FILE}" ]; then
    # Values only for the non-secret keys; HERDR_WEB_TOKEN is reported as set or
    # unset and its value is never printed.
    echo "[pi-docker] plugin env : $(grep -E '^[[:space:]]*(HOST|PORT)=' "${HERDR_WEB_ENV_FILE}" | tr '\n' ' ')"
  fi
  plugin_line="$(herdr plugin list 2>/dev/null | grep -F "${HERDR_WEB_PLUGIN_ID}" | head -n1 || true)"
  echo "[pi-docker] web ui     : ${plugin_line:-NOT REGISTERED}"
  if [ -z "${HERDR_WEB_TOKEN:-}" ] && [ ! -s "${HERDR_WEB_ENV_FILE}" ]; then
    echo "[pi-docker] WARNING    : no HERDR_WEB_TOKEN set"
  elif [ -z "${HERDR_WEB_TOKEN:-}" ] && ! grep -qE '^[[:space:]]*HERDR_WEB_TOKEN=' "${HERDR_WEB_ENV_FILE}"; then
    echo "[pi-docker] WARNING    : no HERDR_WEB_TOKEN set"
  fi
  if [ -z "${HERDR_WEB_TOKEN:-}" ]; then
    # The vendor's own words for this state, worth repeating verbatim: until a
    # device is paired, a proxied address is open to anyone who reaches it. What
    # stands in front of it here is the reverse proxy's login.
    echo "[pi-docker] auth       : no token — pair your devices (see README, 'Logging in'); the proxy's login is the only gate until then"
  else
    echo "[pi-docker] auth       : token set (from HERDR_WEB_TOKEN; the value is never printed)"
  fi
fi

# The herdr server is *ensured* for EVERY invocation, not only the default `serve`:
# the container is a herdr host first, and the tests run other commands in it (a
# smoke script, a shell) that assert herdr's socket, the plugin registration and
# the served UI. Starting the server only under `serve` handed those a container
# with no server at all — which is exactly how it was caught, by a smoke test
# failing on `herdr api snapshot` while the image itself was fine.
#
# "Ensured" is the load-bearing word, and getting it wrong cost another round: a
# second `herdr server` does not fail politely, it takes the socket over from the
# running one, and the plugin's supervisor — a child of the server that just lost
# it — dies with it. Measured on herdr 0.9.3: the server log shows a takeover
# seconds after a live container was `docker exec`'d into, and the web UI stops
# answering. Because the entrypoint runs for `docker exec` as well, *any* command
# run inside a running container would have done that to a user. So the socket is
# asked first, and a server is started only when nothing answers it.
case "${1:-serve}" in
  serve | *)
    # -----------------------------------------------------------------------
    # Herdr runs as the container's main process; the web UI is a plugin that
    # herdr's own startup hook starts, so nothing here runs the UI directly.
    # -----------------------------------------------------------------------
    # `herdr server` is the vendor's "supervised or service-style setup" entry
    # point: it runs the headless server with no client attached, which is
    # exactly a container.
    HERDR_LOG="${HOME}/.herdr/server.log"
    # `herdr server` writes only a short banner to stdout; its real log — and any
    # error worth reading — goes to herdr's own file, beside config.toml. On
    # failure both are dumped, so the reason lands in `docker logs`.
    HERDR_SERVER_LOG="${HERDR_CONFIG_DIR}/herdr-server.log"
    herdr_logs() {
      # $1 is an annotation prefix: pass "::error::" on a fatal path so the reason
      # is readable without repository admin rights (job logs need them), and
      # nothing on the non-fatal warning path so a healthy boot stays quiet.
      # GitHub parses `::error::` lines out of the step's output stream, and a
      # container's stdout/stderr *is* that stream.
      local prefix="${1:-}"
      {
        echo "--- ${HERDR_LOG}" && tail -n 20 "${HERDR_LOG}" 2>/dev/null
        echo "--- ${HERDR_SERVER_LOG}" && tail -n 30 "${HERDR_SERVER_LOG}" 2>/dev/null
        echo "--- plugin log (${HERDR_WEB_PLUGIN_ID})" && herdr plugin log "${HERDR_WEB_PLUGIN_ID}" 2>/dev/null | tail -n 30
      } 2>/dev/null | sed "s|^|${prefix}|" >&2 || true
    }

    # Exactly one server. `herdr api snapshot` goes over the socket and exits
    # non-zero while nothing answers it, which makes it the only correct probe here
    # (`herdr session list` reads session directories locally and exits 0 with no
    # server at all).
    herdr_running() { herdr api snapshot >/dev/null 2>&1; }

    if herdr_running; then
      echo "[pi-docker] herdr server already running; not starting a second one"
      # A command — a shell, a test, `herdr plugin list` — runs against the server
      # that is already there and leaves it alone.
      if [ "${1:-serve}" != "serve" ]; then
        exec "$@"
      fi
      # `serve` must not exit while the server lives, or the container dies with
      # it. Wait on the socket instead of on a pid this invocation does not own.
      while herdr_running; do sleep 2; done
      echo "::error::[pi-docker] herdr server stopped" >&2
      herdr_logs "::error::"
      exit 1
    fi

    echo "[pi-docker] starting herdr server (log: ${HERDR_SERVER_LOG})"
    herdr server >>"${HERDR_LOG}" 2>&1 &
    herdr_pid=$!
    # Forward the container's stop signal to the server instead of leaving it to
    # be killed with the shell.
    trap 'kill -TERM "${herdr_pid}" 2>/dev/null || true' TERM INT QUIT

    ready=0
    # 120s, not 30: the healthcheck's start-period is 90s for the same reason —
    # a cold boot on an empty volume seeds herdr, installs the plugin into the
    # volume and then brings the plugin's own supervisor up, and on a slow CI
    # runner that first start is the slowest thing the container ever does. A
    # budget shorter than the healthcheck's would fail a boot that was going to
    # succeed.
    for _ in $(seq 1 120); do
      if ! kill -0 "${herdr_pid}" 2>/dev/null; then
        echo "::error::[pi-docker] herdr server exited during startup" >&2
        herdr_logs "::error::"
        exit 1
      fi
      # Readiness must come from the socket API: `herdr api snapshot` exits
      # non-zero with code server_not_running until the server is actually
      # listening. `herdr session list --json` is NOT a readiness probe — it is a
      # local command that exits 0 with `"running": false` when nothing is up, so
      # it would report "ready" on the first tick and hand callers a socket that
      # does not exist yet.
      if herdr api snapshot >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    if [ "${ready}" != "1" ]; then
      echo "::error::[pi-docker] herdr server was not reachable after 120s" >&2
      herdr_logs "::error::"
      exit 1
    fi
    echo "[pi-docker] herdr server ready"

    # The web UI starts from herdr's plugin startup hook, a moment after the
    # socket. Waiting for the port here (bounded, non-fatal) is what turns "the
    # container is up but nothing answers" into one clear line in the log.
    web_up=0
    for _ in $(seq 1 40); do
      if (exec 3<>/dev/tcp/127.0.0.1/"${eff_port}") 2>/dev/null; then
        exec 3<&- 2>/dev/null || true
        web_up=1
        break
      fi
      sleep 0.5
    done
    if [ "${web_up}" = "1" ]; then
      echo "[pi-docker] web ui answering on ${eff_host}:${eff_port}"
    else
      echo "[pi-docker] WARNING: nothing is listening on port ${eff_port} after 20s:" >&2
      herdr_logs
    fi

    # On the default `serve` the container lives exactly as long as the server
    # does; the plugin's own stop/start actions restart the UI without touching
    # this. Any other command — a test, `docker run … bash` — gets the server as a
    # background child and decides for itself when the container exits.
    if [ "${1:-serve}" = "serve" ]; then
      wait "${herdr_pid}"
    else
      exec "$@"
    fi
    ;;
esac
