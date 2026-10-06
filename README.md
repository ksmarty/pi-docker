# pi-docker

A self-contained, persistent Docker image for [Herdr](https://herdr.dev), its
[web UI plugin](https://github.com/devswha/herdr-web-ui) (`devswha.herdr-web-ui`),
and the [pi coding agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
CLI.

Herdr runs as the headless terminal multiplexer that owns your panes and the
agents running in them; the web UI plugin is the app you reach them from — a PWA
you install to a phone's home screen; `pi` is on `PATH` inside every pane. The
image bakes herdr's seed, a *built* copy of the plugin, the agent and the build
toolchain in, so the container starts in seconds without network access, and it
funnels **everything persistent** — herdr's state and config, the plugin's
checkout, config and pairing state, the agent's config and sessions, and any tool
the agent installs — into a single `/data` volume plus the `/workspace` project
directory.

The plugin is the only HTTP surface. It has no host allow-list of its own:
first-run access is gated by the plugin's device pairing (and optionally by a
shared `HERDR_WEB_TOKEN`). That is why the compose files publish no port and put
the UI behind your reverse proxy — the Traefik labels plus the `authentik@file`
middleware are part of the deployment, not an afterthought.

```bash
cp .env.example .env                          # set USERDIR and your domain
docker compose -f compose.ghcr.yaml up -d     # published image
# or
docker compose up -d                          # build locally
```

## Quick start

1. `cp .env.example .env` and set `USERDIR` to the host directory that will hold
   the mounts.
2. Edit the Traefik `Host(...)` rule (and, if you are not using `pi.notato.xyz`,
   the `authentik@file` middleware) in the compose file you deploy, and set the
   domain in `.env` to match.
3. Start it:

   ```bash
   docker compose -f compose.ghcr.yaml up -d     # ghcr.io/ksmarty/pi-docker:latest
   # or
   docker compose up -d                          # build locally
   ```

4. Open `https://pi.notato.xyz` (or your own domain) and **pair a device**.
   With no `HERDR_WEB_TOKEN` set, the plugin's own device pairing is the gate, so
   the first visitor to reach an ungated port is the one who pairs. Pairing uses
   a six-digit code the plugin shows; the paired-device state lives in
   `HERDR_WEB_STATE_DIR`, so it is part of your `/data` backup.

`docker compose up --wait` treats an unhealthy container as a failed start; a
first boot on an empty volume seeds the stack before anything binds, which is why
the healthcheck has a generous start period (see [Health](#health)).

## What runs inside

| Process | Role |
| --- | --- |
| `herdr server` | The headless multiplexer. The entrypoint starts it in the background, waits for the **socket API** to answer (`herdr api snapshot`), then supervises it in the foreground (`wait`) — the container lives exactly as long as the server does. Its real log is `~/.config/herdr/herdr-server.log`; the entrypoint's own `~/.herdr/server.log` holds just its startup banner. |
| `devswha.herdr-web-ui` | The Bun web UI / PWA. It is a herdr plugin, not a separate process the entrypoint starts: herdr's own plugin startup hook runs it (`startup: bun scripts/plugin.ts start`), and it listens on `${HERDR_WEB_HOST}:${HERDR_WEB_PORT}`. |
| `pi` | The coding-agent CLI, on `PATH` in every pane along with the rest of the image's toolchain. |

The startup sequence is: prepare `/data` → seed herdr and the plugin when
missing → write the plugin's settings file → clean migrated installs → symlink
the bundled skills → write `/etc/profile.d/pi-paths.sh` → `herdr server` →
`herdr api snapshot` → wait (bounded) for the web UI port. Because the plugin
comes up from herdr's hook, the entrypoint waits on the socket first and the
port second, and the readiness probe is the socket API — `herdr session list` is
a local command that exits 0 even when no server is up, so it would report ready
against a dead server.

## The persistence model

Everything that must survive a rebuild, a `docker compose down`, or a restart
lives in two mounts:

| Mount | Env | Holds |
| --- | --- | --- |
| `/data/home` | `HOME` | `~/.herdr` (state, snapshots, worktrees); `~/.config/herdr` (`config.toml`, `plugins.json`, the plugin checkout under `plugins/github/`, and the plugin's `config/devswha.herdr-web-ui/env`); `~/.config/herdr-web-ui` (pairing, push keys, device subscriptions, update builds); the `~/.npm` cache; `~/.local/bin` (`pip --user`, uv, pipx, the `herdr` binary); `~/.cargo`; `~/go`; `~/.bun` |
| `/data/agent` | `PI_CODING_AGENT_DIR` | pi config, API keys, sessions, packages/extensions, `skills/`, and its own `bin/` |
| `/data/npm` | `NPM_CONFIG_PREFIX` | every `npm install -g <tool>` the agent performs (never the apps — see below) |
| `/workspace` | `PI_WORKSPACE_DIR` | the agent's project files |

`/data` is a single volume, so one bind mount (`${USERDIR}/data/pi/data:/data`)
captures all of it. A backup is one tar of `$USERDIR/data/pi` (see
[Backup and restore](#backup-and-restore)).

### Installing tools that stick

Because `HOME` and `NPM_CONFIG_PREFIX` point into the volume, the agent can
install tools at runtime and they are still there after a restart *and* a
container recreate:

```bash
npm install -g some-cli          # -> /data/npm/bin/some-cli        (persisted)
pip install --user some-python   # -> /data/home/.local/bin/...    (persisted)
pipx install some-python-cli      # -> /data/home/.local/bin/...    (persisted)
uv tool install some-python-cli   # -> /data/home/.local/bin/...    (persisted)
cargo install some-rust-cli       # -> /data/home/.cargo/bin/...    (persisted)
go install example.com/x@latest   # -> /data/home/go/bin/...        (persisted)
bun add -g some-tool              # -> /data/home/.bun/bin/...      (persisted)
curl -o /data/npm/bin/x <url> && chmod +x /data/npm/bin/x   # standalone binary
```

All of those directories are already on `PATH` — for the container's main process
**and** for the panes the web UI shows (the entrypoint also writes
`/etc/profile.d/pi-paths.sh`). `apt-get install` writes to the container
filesystem, not the volume: it survives a plain restart but is gone the next time
the container is recreated (image update, `docker compose down && up`, fresh
deploy) and is not in a `/data` backup. Use it for one-off system packages only,
or add the package to the `Dockerfile`.

The image ships `node` (the chosen `NODE_VERSION` line), `npm`, `bun`, `python3`
+ `pip`, `make`/`g++` for native modules, `git`, `ripgrep`, `curl`, `jq`,
`unzip` and a few small utilities. The PEP 668 "externally managed" marker is
removed so `pip install --user` works — the runtime that is *not* baked in (uv,
pipx, cargo, go) still installs into `$HOME` and persists, because `$HOME` is on
the volume.

The bundled [`persistent-tool-install`](skills/persistent-tool-install/SKILL.md)
skill covers the details. Its one hard rule: **never** install the image's own
packages — the pi CLI, `bun`, or `herdr` — with `npm install -g`. `/usr/local`
comes first on `PATH` (ahead of `/data/npm/bin`), so a volume copy is inert and
shadowed; the entrypoint additionally deletes any `@earendil-works/pi-coding-agent`
it finds in `/data/npm` at startup. To update the pi CLI, update the image.

### Herdr and the web UI plugin live in the volume

Both apps are **seeded from the image into the volume on first start**, not
installed into `/data` at build time and not symlinked out of the image:

- an empty volume boots a complete, working stack with no network access;
- `herdr update`, `herdr plugin update` and the web UI's **Settings → Updates**
  write into the volume, so a self-update survives a restart **and** a container
  recreate (`docker compose down && up`);
- the entrypoint never overwrites an existing install, so an image rebuild cannot
  clobber a version you updated to;
- the seeded herdr is a real binary at `$HOME/.local/bin/herdr`, and the plugin is
  a real checkout (with its `node_modules`) under
  `$HOME/.config/herdr/plugins/github/devswha.herdr-web-ui` — neither is a symlink
  back into the image, which is what makes their in-place updaters land somewhere
  that persists.

The trade-off is deliberate: after a self-update the volume copy and the image's
seed can differ, and the volume wins. To return to the version baked into the
image, remove the install and restart:

```bash
rm -f  /data/home/.local/bin/herdr
rm -rf /data/home/.config/herdr/plugins /data/home/.config/herdr/plugins.json
docker compose restart
```

### The bundled skills

The image ships two skills and publishes both to the agent at startup:

| Skill | Source | Covers |
| --- | --- | --- |
| [`persistent-tool-install`](skills/persistent-tool-install/SKILL.md) | this repo | Which install paths survive a restart, a recreate and a fresh deploy — and which silently do not. |
| `herdr` | generated at build time from `herdr --skill` | Driving panes, tabs, workspaces and the agents inside them, as the installed herdr version documents it (the vendor's own text, so it cannot drift from the binary). |

The entrypoint symlinks each one into `${PI_CODING_AGENT_DIR}/skills/`, where pi
discovers global skills, so they are available out of the box (including to
`/skill:herdr` and `/skill:persistent-tool-install`), an image rebuild updates
them because the links point into the image, and a skill *you* replace with a real
directory of the same name is left untouched.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `HERDR_WEB_HOST` | `0.0.0.0` | Bind address for the plugin. `0.0.0.0` because a reverse proxy in a *sibling* container cannot reach this container's `127.0.0.1`; the plugin's own default is loopback. |
| `HERDR_WEB_PORT` | `7317` | HTTP port the plugin binds. Keep the Traefik loadbalancer label in step. |
| `HERDR_WEB_TOKEN` | *(unset)* | Optional shared secret. Unset leaves the plugin's own device pairing in charge; set it to require a secret as well. The vendor recommends a token for any deployment behind a reverse proxy. |
| `HERDR_INSTALL_DIR` | `/data/home/.local/bin` | Where the `herdr` binary lives in the volume. |
| `HERDR_CONFIG_PATH` | `/data/home/.config/herdr/config.toml` | Seeded with `onboarding = false` on first start; yours after that. |
| `HERDR_WEB_STATE_DIR` | `/data/home/.config/herdr-web-ui` | Pairing, push keys, device subscriptions and update builds. Set by the entrypoint; losing this directory means re-pairing every device. |
| `HERDR_PROCESS_DETECTION` | `child-groups` | Container runtimes often do not expose the foreground process group herdr's default detection expects. |
| `PI_WORKSPACE_DIR` | `/workspace` | Directory the agent works in. |
| `PI_CODING_AGENT_DIR` | `/data/agent` | pi config, sessions, API keys. |
| `NPM_CONFIG_PREFIX` | `/data/npm` | Global npm prefix — the persisted tool directory. |
| `HOME` | `/data/home` | Persisted home for the agent, its tools and both apps. |
| `PI_APP_SEED` | `/opt/pi-docker/seed` | Where the image's herdr and plugin seed live; read by the entrypoint. |

`.env.example` also declares `PI_PUBLIC_URL` — optional, because the plugin builds
the public address from the request it receives; set it if you terminate TLS
somewhere other than the proxy that reaches the container. The shipped compose
files do not forward it into the container.

Everything above is an ordinary environment variable, so anything the vendors
document as configurable can also go in your compose file.

### Where HOST and PORT actually come from

`HERDR_WEB_HOST`, `HERDR_WEB_PORT` and `HERDR_WEB_TOKEN` are *this image's* knobs,
not the plugin's own variable names. The plugin reads its settings from its
config env file — `$HOME/.config/herdr/plugins/config/devswha.herdr-web-ui/env`
(`herdr plugin config-dir devswha.herdr-web-ui` prints the directory) — and
**that file wins over the process environment**.

The entrypoint translates the two container variables into that file on first
start and only appends a key that is not already present:

```
HOST=0.0.0.0
PORT=7317
```

So a `HOST`/`PORT` you put in the file yourself wins, and — the thing users get
wrong — **changing `HERDR_WEB_HOST`/`HERDR_WEB_PORT` after first start has no
effect**, because the key already exists in the volume. Edit (or delete) that file
and restart to change it. The entrypoint prints the *effective* bind it read back
from the file, so a file that disagrees with the compose file is visible in the
log rather than mysterious:

```
[pi-docker] web ui bind: 0.0.0.0:7317  (state: /data/home/.config/herdr-web-ui)
[pi-docker] plugin env : HOST=0.0.0.0 PORT=7317
```

`HERDR_WEB_TOKEN`, when set, is written into the same file and `chmod 600`; its
value is never printed. If the port is exposed in any way, set a token.

### Pairing a device

The plugin authorizes per device, and pairing is the credential. Open the UI and
pair — the plugin shows a six-digit code. The paired-device state lives under
`HERDR_WEB_STATE_DIR` (`/data/home/.config/herdr-web-ui`), so restoring the
`/data` volume keeps your devices paired. With no `HERDR_WEB_TOKEN`, the
`authentik@file` login in front of the proxy is the **only** gate until the first
device pairs, and the entrypoint says so on every start:

```
[pi-docker] auth : no token — pair your devices; the proxy's login is the only gate until then
```

### Versions

Everything is baked at build time and can be pinned:

```bash
docker build \
  --build-arg HERDR_VERSION=0.9.3 \
  --build-arg HERDR_WEB_UI_VERSION=v0.3.50 \
  --build-arg PI_CODING_AGENT_VERSION=latest \
  --build-arg NODE_VERSION=26 \
  -t pi-docker .
```

- `HERDR_VERSION` defaults to `latest`, which uses herdr's installer and verifies
  the checksum from `herdr.dev/latest.json`. With an explicit version the build
  **asserts** it got that release and fails instead of moving past your pin.
- `HERDR_WEB_UI_VERSION` defaults to `v0.3.50` and is *pinned on purpose*: the
  plugin is the app this image exposes, and `latest` would make an image rebuild a
  silent upgrade of the thing users log into. It is the git ref passed to
  `herdr plugin install devswha/herdr-web-ui --ref`. Bump it to update, or use
  Settings → Updates in the web UI (that path persists).
- `PI_CODING_AGENT_VERSION` defaults to `latest` and is installed with
  `npm install --global "@earendil-works/pi-coding-agent@<version>"` into
  `/usr/local`.
- `NODE_VERSION` picks the `node:<major>-bookworm-slim` base and defaults to `26`
  (current LTS); `24` is also supported. CI builds both on every change.
- `VERSION` and `COMMIT` (defaults `dev` / `unknown`) are image labels supplied by
  the release workflow.

## Reverse proxy

The compose files carry the Traefik labels used in production:

```yaml
labels:
  - traefik.enable=true
  - traefik.http.routers.pi.rule=Host(`pi.notato.xyz`)
  - traefik.http.routers.pi.middlewares=authentik@file
  - traefik.http.services.pi.loadbalancer.server.port=7317
```

To use your own hostname, change the `Host(...)` rule in both the compose file and
`.env` (and adjust the middleware if you do not run `authentik@file`).

**Do not publish the port.** Traefik reaches the container over the shared docker
network, and the plugin has no host allow-list of its own — a published port puts
the UI on every interface of the host, where the first unauthenticated visitor is
the one who gets to pair it. The compose files leave `ports:` out for this reason.
If you really need direct access, publish it *and* set `HERDR_WEB_TOKEN`, so the
port is not the only gate.

One deviation is unavoidable in the default layout: a proxy in a *sibling*
container cannot reach this container's loopback, so the image binds `0.0.0.0`.
The cost is that anything inside the container can reach the port; here that is
root and nothing else. If your proxy runs on the host, set `HERDR_WEB_HOST` to
`127.0.0.1` — but then the UI is unreachable from a sibling Traefik container.

## Health

The image declares a healthcheck against `GET /api/health`:

```bash
docker inspect --format '{{.State.Health.Status}}' pi
```

The probe connects to loopback, reads the port from the plugin's own env file
first (falling back to `HERDR_WEB_PORT`), and requires a 200 **and** `"ok":true`:

```
{"ok":true,"herdr":{"version":…,"protocol":22},"auth":{…},"web_ui":{"boot_id":…,"revision":…}}
```

`ok:true` is the vendor's liveness field and proves both halves are alive: the
plugin (`web_ui.boot_id`) and its socket link to the herdr server (`herdr`). The
route is **unauthenticated by design**, so the probe keeps working with a
`HERDR_WEB_TOKEN` set — that is what makes the locked-down deployment the one CI
tests. `/health` without the `/api` prefix is the single-page-app shell, **not** a
health endpoint; do not probe it. A container whose server is up but whose UI
never came up must not look healthy, which is exactly what `ok:true` catches. On
failure the probe prints the status code and body to stderr, which lands in
`docker inspect`'s health log.

## Updating

Two things can update, and they are independent:

```bash
docker compose pull && docker compose up -d     # image: pi CLI, seeds, base image
docker compose up -d --build                    # local build instead of pull
```

The apps update themselves, and those updates persist:

```bash
herdr update                  # inside a pane, or via the web UI's Settings -> Updates
herdr plugin update devswha.herdr-web-ui
```

The pi CLI is the exception: it is a package installed into the image, so it
changes when the image does. `/usr/local/bin` comes first on `PATH`, so a stale
copy in `/data/npm` can never shadow it.

## Backup and restore

Everything is under one directory. Stop, copy, done:

```bash
docker compose down
tar czf pi-backup-$(date +%F).tar.gz -C "$USERDIR/data" pi
docker compose up -d
```

Restoring is the same in reverse: unpack so that `data/pi/data` and
`data/pi/workspace` are back in place. The plugin's pairing and herdr's sessions
come back with it.

## Migrating from Collie or pi-web-ui

This image replaces the earlier Collie / pi-web-ui stack. The volume needs **no
migration**: same `/data`, same `HOME`, same agent dir. The compose service was
renamed, so let compose remove the old container on the way in:

```bash
docker compose -f compose.ghcr.yaml up -d --remove-orphans
```

The stale install the old stack left inside the volume is cleaned automatically
on first start. The entrypoint removes `pi-web-ui` and
`@earendil-works/pi-coding-agent` from `${NPM_CONFIG_PREFIX}/lib/node_modules`
and any dangling `${NPM_CONFIG_PREFIX}/bin/{pi-web-ui,pi}` symlinks — the old
compose installed them into the persisted npm prefix, and both are now owned by
the image. The removal is narrow: `/data/npm` is where the agent's own tools
live, so nothing else is wiped and a real file you put in `bin/` is left alone.
It is also guarded: it only runs when the image's own herdr seed is present
(`${PI_APP_SEED}/bin/herdr`), so running the entrypoint against a volume where
`/data/npm` holds the *only* install is a no-op.

## Plain `docker run`

```bash
docker run -d --init --name pi \
  -v "$PWD/data:/data" \
  -v "$PWD/workspace:/workspace" \
  -p 127.0.0.1:7317:7317 \
  -e HERDR_WEB_TOKEN=change-me \
  pi-docker
```

This is the **direct-access** form: loopback-only, with a token, so it is safe to
expose on the host's loopback. To put it behind a proxy on a public hostname,
drop `-p` and reach it over the docker network instead.

`--init` is recommended (the panes spawn shell/agent children). Passing a command
other than the default `serve` is exec'd as-is, which is how the CI tests get a
shell through the real entrypoint:

```bash
docker run --rm -it pi-docker bash
```

## CI & releases

| Workflow | Trigger | Does |
| --- | --- | --- |
| `.github/workflows/ci.yml` | push to `main`, every PR | Builds `linux/amd64` on **Node 24 and 26**, then runs the image-facing tests: smoke (`herdr`, `pi`, `bun`, `node` and the toolchain present and runnable; the plugin registered, enabled and pointing into the volume; both bundled skills discovered by pi's own loader), a fresh empty-volume boot reaching **healthy**, the web UI's HTTP contract, persistence across restart **and** container recreate, and the migrated-install cleanup. It also validates both compose files and shell-parses the entrypoint and test scripts. |
| `.github/workflows/release.yml` | push to `main`, manual dispatch | Computes the next semver tag from conventional commits, builds and pushes a multi-arch (`linux/amd64`, `linux/arm64`) image to **`ghcr.io/ksmarty/pi-docker`** with a semver tag and `latest`, and creates a GitHub Release. `provenance`/`sbom` are off and the cache export is `type=gha,mode=min`. |

Commits are classified the usual way: `feat!:` / `BREAKING CHANGE` → major,
`feat:` → minor, anything else → patch. Manual runs choose the bump.

## Verifying a change

There is no test suite to run locally — the "build" is `docker build` and the
tests boot the built image. When Docker is available:

```bash
docker build -t pi-docker:test .
docker run --rm --entrypoint bash pi-docker:test -lc 'command -v herdr pi bun node npm'
docker compose -f docker-compose.yml config >/dev/null
docker compose -f compose.ghcr.yaml config >/dev/null
```

The image-facing assertions live in `scripts/*.sh` and are piped into the
container by CI as `bash -lc "$(cat scripts/<name>.sh)"`. Each script runs
`set -eEuo pipefail` with an `ERR` trap that annotates the failing line, and on
failure dumps the container logs and docker's own health probe output (as
`::error::` annotations, because job logs need repo-admin rights). They default to
the image layout but keep `NPM_CONFIG_PREFIX`, `ENTRYPOINT`, `PI_IMAGE_PREFIX` and
`HERDR_INSTALL_DIR` overridable so they can be exercised against a throwaway
prefix without touching a real `/data`.

What the scripts actually assert:

- `ci-smoke.sh` — node/npm/bun/pi/herdr run; the pi CLI and `bun` resolve to
  `/usr/local/bin`; `/etc/profile.d/pi-paths.sh` and the `/data` dirs exist; the
  herdr seed exists and the **volume** copy is what runs; `herdr api snapshot`
  answers; the plugin checkout, `node_modules`, `entry.js` and registry entry
  exist and all recorded paths resolve inside `$HOME` with `enabled: true`; the
  plugin's `env` file has `HOST=`/`PORT=`; `make g++ python3 rg git curl` and pip
  work; the PEP 668 marker is gone; the migrated web UI package and the pi CLI
  are not in `/data/npm`; and both skills are discovered by pi's loader.
- `ci-health.sh` — a fresh, no-volume boot reaches `healthy` on its own; the log
  banner reports the effective bind; `herdr api snapshot` answers and the seeded
  herdr is not a symlink; the plugin is seeded into the volume and running; and
  `/api/health` reports `"ok":true`.
- `ci-web-ui.sh` — with a token set: `GET /` is 200 HTML; `GET /api/health` is 200
  `"ok":true` with `"herdr"` and `"web_ui"`; a foreign `Host` changes nothing
  (this plugin has no host allow-list); and `GET /health` is the SPA, not JSON.
- `ci-persistence.sh` — a tool installed into `/data/npm` is on `PATH` after a
  restart *and* a recreate; agent state, sessions, `/workspace` files and a
  user-owned skill survive; a change inside the seeded herdr and a plugin update
  are **not** overwritten; and the UI still serves after a recreate.
- `ci-migrated-install.sh` — the migrated web UI and pi CLI copies and their
  dangling bin links are removed while other `/data/npm` tools and real `bin`
  files are kept; the cleanup is skipped when the image seed is absent; it is
  idempotent; and seeding never overwrites an existing install.

## Repository layout

```
Dockerfile              single-stage image (ARG NODE_VERSION, default node:26-bookworm-slim)
docker-entrypoint.sh    prepares the volume, seeds herdr + plugin, starts herdr, supervises it
config/                 herdr config seeded on first start
scripts/                shell tests CI runs against the built image
skills/                 agent skills baked into the image (symlinked into the agent dir)
docker-compose.yml      local build
compose.ghcr.yaml       published image (Traefik ready)
.env.example            USERDIR / domain / web UI knobs / version pins
.github/workflows/      CI + release
```

## License

MIT — see [`LICENSE`](LICENSE).
