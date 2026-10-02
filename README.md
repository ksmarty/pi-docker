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

That works while no host allow-list is set. As soon as `PI_WEB_ALLOW_HOSTS` is
set, the app serves **only** those hostnames and answers everything else with
`403 host not allowed` — including `127.0.0.1`. See [Health](#health).

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

The original compose installed the app into `/data/npm` on first boot. On
startup the entrypoint now **removes those migrated copies automatically**:

```
[pi-docker] removing stale pi-web-ui from /data/npm/lib/node_modules (the image provides it now)
[pi-docker] removing dangling /data/npm/bin/pi-web-ui
```

That matters because `/data/npm` is now reserved for the tools the agent
installs; a leftover app copy there would be a second version of pi-web-ui
sharing an SDK version with the image, which is how you get two servers or a
mismatched dependency tree. The removal is deliberately narrow — only those two
package directories and their `bin` symlinks. Anything else the agent installed
into `/data/npm` is left alone. If nothing stale is present, the entrypoint says
nothing and no `bin` entry is ever deleted.

It is also guarded: the cleanup only runs when the image's own copy is present
at `/usr/local/bin/pi-web-ui`. Running this entrypoint against a volume where
`/data/npm` holds the *only* pi-web-ui (an older container, a host shell) leaves
it alone instead of deleting the installation you depend on. Override the
location with `PI_WEB_IMAGE_PREFIX` if your build puts the app elsewhere.

No manual cleanup step is required; `docker compose up -d` is enough.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PI_WEB_HOST` | `0.0.0.0` | Listen address. Keep `0.0.0.0` for port mapping. |
| `PI_WEB_PORT` | `8787` | HTTP port. |
| `PI_WEB_CWD` | `/workspace` | Directory the agent works in. |
| `PI_WEB_DATA_DIR` | `/data/home/.pi-web` | UI state, plugins, uploads. |
| `PI_CODING_AGENT_DIR` | `/data/agent` | pi config, sessions, API keys. |
| `PI_WEB_MANAGED` | `1` | Managed mode: the in-app updater and plugin-market installs *refuse*, because the image is the source of truth. |
| `PI_WEB_ALLOW_HOSTS` | *(unset)* | Allow-list of `Host` hostnames, e.g. `pi.example.com`. **Setting it turns on strict mode**: every other `Host`, including `127.0.0.1`, is refused with `403 host not allowed`. Unset = loopback and private LAN addresses accepted. |
| `PI_WEB_ALLOW_ORIGINS` | *(unset)* | Allow-list of `Origin` values for the websocket upgrade, e.g. `https://pi.example.com`. |
| `PI_WEB_TOKEN` | *(unset)* | If set, the UI requires `/?token=<value>` once, then sets a cookie. |
| `NPM_CONFIG_PREFIX` | `/data/npm` | Global npm prefix — the persisted tool directory. |
| `HOME` | `/data/home` | Persisted home for the agent and its tools. |

Behind a reverse proxy (Traefik, Caddy, nginx), set `PI_WEB_ALLOW_HOSTS` and
`PI_WEB_ALLOW_ORIGINS` to your public hostname/origin — otherwise the websocket
upgrade is rejected, and in strict mode HTTP requests are too.

In that setup do **not** publish the port (`-p 8787:8787`). The proxy reaches the
container over the docker network, and a published port only invites requests
the app will refuse: `http://<server-ip>:8787` returns a bare 403 that looks like
the container is down. The compose files leave `ports:` out for this reason.

### Versions

Both packages are installed at build time and can be pinned:

```bash
docker build \
  --build-arg PI_WEB_UI_VERSION=0.85.0 \
  --build-arg PI_CODING_AGENT_VERSION=0.85.1 \
  --build-arg NODE_VERSION=26 \
  -t pi-docker .
```

Defaults to `latest`. In compose these are `${PI_WEB_UI_VERSION}` /
`${PI_CODING_AGENT_VERSION}`.

`NODE_VERSION` picks the `node:<major>-bookworm-slim` base and defaults to `26`
(current LTS); `24` is also supported. Both are built by CI on every change,
because `node-pty` ships no Linux prebuild and is compiled from source here — a
Node bump is exactly the change that breaks it silently.

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
docker run -d --init --name pi-web-ui -p 127.0.0.1:8787:8787 \
  -v "$PWD/data:/data" \
  -v "$PWD/workspace:/workspace" \
  pi-docker
```

This is the **direct-access** form: no host allow-list, so `localhost` and LAN
requests are accepted. To put it behind a proxy on a public hostname, drop `-p`
and set the allow-lists instead:

```bash
docker run -d --init --name pi-web-ui \
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

The probe sends a `Host` header taken from the **first entry of
`PI_WEB_ALLOW_HOSTS`** rather than `127.0.0.1`. Under strict mode the app
refuses the loopback host, so a plain `127.0.0.1` probe would get 403 forever
and the container would sit at `unhealthy` while serving perfectly well — that
was the v0.1.0 bug. The same rule applies to your own checks:

```bash
# allowed host -> 200, bare loopback -> 403 in strict mode (both expected)
curl -s -o /dev/null -w 'allowed  %{http_code}\n' -H 'Host: pi.notato.xyz' http://127.0.0.1:8787/api/health
curl -s -o /dev/null -w 'loopback %{http_code}\n' http://127.0.0.1:8787/api/health
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
| `.github/workflows/ci.yml` | push to `main`, every PR | Builds the image for `linux/amd64` on **Node 24 and 26**, smoke-tests that `pi-web-ui`/`pi` are on `PATH` and the CLI runs, that `node-pty` loads, that the bundled skill is discoverable, that a strict host allow-list still yields a **healthy** container, that the host guard answers only the allowed host, and that the entrypoint cleans up migrated installs. Validates both compose files. |
| `.github/workflows/release.yml` | push to `main`, manual dispatch | Computes the next semver tag from conventional commits, builds and pushes a multi-arch (`amd64`/`arm64`) image to GHCR, creates a GitHub Release. |

Commits are classified the usual way: `feat!:`/`BREAKING CHANGE` → major,
`feat:` → minor, anything else → patch. Manual runs choose the bump.

## Notes

- The container runs as **root** by design: the agent installs system packages
  and writes into host bind mounts. To run unprivileged, add `user: "1000:1000"`
  (or similar) **and** `chown` the host directories to that uid.
- The C/C++ toolchain is intentionally kept in the final image so the agent can
  rebuild native modules; this trades some image size for a working `npm i -g`.
- **The container serves nothing to an unexpected `Host`.** If the UI seems
  down, check the first lines of `docker logs` — the entrypoint prints the
  effective bind/allow-list (`[pi-docker] hosts : ...`) — and ask for the
  allowed hostname:

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: pi.notato.xyz' http://127.0.0.1:8787/
  ```

  A `403` means the app is up and the host allow-list is doing its job.

## Repository layout

```
Dockerfile              single-stage image (NODE_VERSION, default node:26-bookworm-slim)
docker-entrypoint.sh    creates the persisted dirs, cleans migrated installs, links skills, fixes PATH, execs the server
scripts/               shell tests CI runs against the built image (smoke, healthcheck, host guard, cleanup)
skills/                 agent skills baked into the image (symlinked into the agent dir)
docker-compose.yml      local build
compose.ghcr.yaml       published image (Traefik ready)
.env.example            USERDIR / host-origin / token
.github/workflows/      CI + release
```

## License

MIT — see [LICENSE](LICENSE). pi and pi-web-ui are MIT-licensed projects by their
respective authors.
