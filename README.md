# pi-docker

A self-contained Docker image for the [pi coding agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
and its web UI, [pi-web-ui](https://www.npmjs.com/package/pi-web-ui).

It bakes the app and its build toolchain into the image so the container starts
in seconds, and it funnels **everything persistent** — pi's config and sessions,
the UI state, and any tool the agent installs — into a single `/data` volume plus
the `/workspace` project directory.

```bash
docker compose -f compose.ghcr.yaml up -d     # published image
# or
docker compose up -d                          # build locally
```

Then open `http://localhost:8787`.

---

## The persistence model

Everything that must survive a rebuild, a `docker compose down`, or a restart
lives in two mounts:

| Mount | Env | Holds |
| --- | --- | --- |
| `/data/home` | `HOME` | `~/.pi-web` (UI state, plugins, uploads), `~/.npm` cache, `~/.local/bin` (`pip --user`, `uv`, `pipx`), `~/.cargo`, `~/go`, `~/.bun` |
| `/data/agent` | `PI_CODING_AGENT_DIR` | pi's config, API keys, sessions, packages/extensions, `skills/`, and its own `bin/` |
| `/data/npm` | `NPM_CONFIG_PREFIX` | every `npm install -g <tool>` the agent performs (not the app itself — that lives in the image) |
| `/workspace` | `PI_WEB_CWD` | the agent's project files |

`/data` is a single volume, so one bind mount (`${USERDIR}/data/pi/data:/data`)
captures all of it.

### Installing tools that stick

Because `NPM_CONFIG_PREFIX` points into the volume and `HOME` does too, the agent
can install tools at runtime and they are still there after a restart:

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

All of those directories are already on `PATH` — for the server process **and**
for the web UI's terminal tab (the entrypoint also writes
`/etc/profile.d/pi-paths.sh`). `apt-get install` writes to the container
filesystem, not the volume: it survives a plain restart but is gone the next time
the container is recreated, and it is not in a `/data` backup. Use it for one-off
system packages only, or add the package to the `Dockerfile`.

The image ships the C/C++ toolchain (`python3`, `make`, `g++`) on purpose: many
npm packages with native bindings (including `node-pty`) compile on install. The
PEP 668 "externally managed" marker is removed so `pip install --user` works —
the toolchains that are *not* built in (`uv`, `pipx`, `cargo`, `go`, `bun`) still
install into `$HOME` and persist, because `HOME` is on the volume.

### The bundled skill

The image ships an agent skill that documents exactly this —
[`skills/persistent-tool-install/`](skills/persistent-tool-install/SKILL.md) — so
the agent knows which install paths survive a restart and which do not, without
being told. The entrypoint symlinks it into `${PI_CODING_AGENT_DIR}/skills/`
(where pi discovers global skills), so:

- it is available out of the box, including to `/skill:persistent-tool-install`;
- an image rebuild updates it, because the link points into the image, not a copy;
- a skill *you* replace with a real directory of the same name is left untouched.
It covers one gotcha worth repeating: never `npm install -g pi-web-ui` or the
`pi` CLI — the image manages those (`PI_WEB_MANAGED=1`), and the copy would be
shadowed by `/usr/local` anyway.

### Updates

pi-web-ui is **managed by the image**: it is installed at `/usr/local`, which
comes first on `PATH`. `PI_WEB_MANAGED=1` makes the in-app updater refuse by
design ("managed from outside") — the update panel is meant to be driven by
whoever deploys the image.

To update:

```bash
docker compose pull && docker compose up -d      # published image
docker compose up -d --build                     # local build
```

Because `/data/npm` is *not* first on `PATH`, an older pi-web-ui left there by a
previous first-start install cannot shadow the baked one. `/data/npm` stays on
`PATH`, so the extra tools the agent installs there keep working.

### Migrating from the first-start install

The original compose installed pi into `/data/npm` on first boot. That data keeps
working as-is, but those app copies are now unused and shadowed. Optionally
reclaim the space — this does **not** touch extra tools you installed:

```bash
docker compose down
sudo rm -rf "$USERDIR/data/pi/data/npm/lib/node_modules/pi-web-ui" \
            "$USERDIR/data/pi/data/npm/lib/node_modules/@earendil-works" \
            "$USERDIR/data/pi/data/npm/bin/pi-web-ui" \
            "$USERDIR/data/pi/data/npm/bin/pi"
docker compose up -d
```

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PI_WEB_HOST` | `0.0.0.0` | Listen address. Keep `0.0.0.0` for port mapping. |
| `PI_WEB_PORT` | `8787` | HTTP port. |
| `PI_WEB_CWD` | `/workspace` | Directory the agent works in. |
| `PI_WEB_DATA_DIR` | `/data/home/.pi-web` | UI state, plugins, uploads. |
| `PI_CODING_AGENT_DIR` | `/data/agent` | pi config, sessions, API keys. |
| `PI_WEB_MANAGED` | `1` | Managed mode: the in-app updater and plugin-market installs *refuse*, because the image is the source of truth. |
| `PI_WEB_ALLOW_HOSTS` | *(unset)* | Allow-list of `Host` hostnames for the websocket upgrade, e.g. `pi.example.com`. Unset = no host check. |
| `PI_WEB_ALLOW_ORIGINS` | *(unset)* | Allow-list of `Origin` values for the websocket upgrade, e.g. `https://pi.example.com`. |
| `PI_WEB_TOKEN` | *(unset)* | If set, the UI requires `/?token=<value>` once, then sets a cookie. |
| `NPM_CONFIG_PREFIX` | `/data/npm` | Global npm prefix — the persisted tool directory. |
| `HOME` | `/data/home` | Persisted home for the agent and its tools. |

Behind a reverse proxy (Traefik, Caddy, nginx), set `PI_WEB_ALLOW_HOSTS` and
`PI_WEB_ALLOW_ORIGINS` to your public hostname/origin or the websocket upgrade
will be rejected.

### Versions

Both packages are installed at build time and can be pinned:

```bash
docker build \
  --build-arg PI_WEB_UI_VERSION=0.85.0 \
  --build-arg PI_CODING_AGENT_VERSION=0.85.1 \
  -t pi-docker .
```

Defaults to `latest`. In compose these are `${PI_WEB_UI_VERSION}` /
`${PI_CODING_AGENT_VERSION}`.

## Run the published image (GHCR)

The image is published by the Release workflow to
**`ghcr.io/ksmarty/pi-docker`**, tagged with a semver version and `latest`.

```bash
cp .env.example .env      # set USERDIR (and your domain)
docker compose -f compose.ghcr.yaml up -d
```

`compose.ghcr.yaml` includes the Traefik labels used in production
(`pi.notato.xyz`, `authentik@file` middleware) — adjust or delete them for your
setup. The GHCR package is public, so `docker pull` needs no authentication;
make it private in the package settings if you would rather it were not.

## Run with docker compose (local build)

```bash
docker compose up -d --build
docker compose logs -f
```

`docker-compose.yml` mounts `${USERDIR}/data/pi/data` and
`${USERDIR}/data/pi/workspace`; set `USERDIR` in `.env` first (see
`.env.example`).

## Plain `docker run`

```bash
docker run -d --init --name pi-web-ui -p 8787:8787 \
  -v "$PWD/data:/data" \
  -v "$PWD/workspace:/workspace" \
  -e PI_WEB_ALLOW_HOSTS=pi.example.com \
  -e PI_WEB_ALLOW_ORIGINS=https://pi.example.com \
  pi-docker
```

`--init` is recommended (the image runs the server as PID 1 and the agent spawns
shell/PTY children).

## Health

The image declares a healthcheck against `GET /api/health`:

```bash
docker inspect --format '{{.State.Health.Status}}' pi-web-ui
```

`/api/health` is intentionally unauthenticated (it exposes no secrets), so it
works even when `PI_WEB_TOKEN` is set.

## Backup and restore

Everything is under one directory. Stop, copy, done:

```bash
docker compose down
tar czf pi-backup-$(date +%F).tar.gz -C "$USERDIR/data" pi
docker compose up -d
```

Restoring is the same in reverse: unpack so that `data/pi/data` and
`data/pi/workspace` are back in place.

## CI & releases

| Workflow | Trigger | Does |
| --- | --- | --- |
| `.github/workflows/ci.yml` | push to `main`, every PR | Builds the image for `linux/amd64`, smoke-tests that `pi-web-ui`/`pi` are on `PATH` and the CLI runs, validates both compose files. |
| `.github/workflows/release.yml` | push to `main`, manual dispatch | Computes the next semver tag from conventional commits, builds and pushes a multi-arch (`amd64`/`arm64`) image to GHCR, creates a GitHub Release. |

Commits are classified the usual way: `feat!:`/`BREAKING CHANGE` → major,
`feat:` → minor, anything else → patch. Manual runs choose the bump.

## Notes

- The container runs as **root** by design: the agent installs system packages
  and writes into host bind mounts. To run unprivileged, add `user: "1000:1000"`
  (or similar) **and** `chown` the host directories to that uid.
- The C/C++ toolchain is intentionally kept in the final image so the agent can
  rebuild native modules; this trades some image size for a working `npm i -g`.

## Repository layout

```
Dockerfile              single-stage image (node:22-bookworm-slim)
docker-entrypoint.sh    creates the persisted dirs, links skills, fixes PATH, execs the server
skills/                 agent skills baked into the image (symlinked into the agent dir)
docker-compose.yml      local build
compose.ghcr.yaml       published image (Traefik ready)
.env.example            USERDIR / host-origin / token
.github/workflows/      CI + release
```

## License

MIT — see [LICENSE](LICENSE). pi and pi-web-ui are MIT-licensed projects by their
respective authors.
