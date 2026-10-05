# pi-docker

A self-contained, persistent Docker image for [Herdr](https://herdr.dev) and the
[Collie PWA](https://colliepwa.dev), plus the
[pi coding agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
CLI.

Herdr runs as the terminal multiplexer holding your panes and agents; Collie is
the web app you reach them from; `pi` is available inside those panes. The image
bakes both apps, the agent and the build toolchain in, so the container starts in
seconds, and it funnels **everything persistent** — herdr's state, Collie's
config and pairing, the agent's config and sessions, and any tool the agent
installs — into a single `/data` volume plus the `/workspace` project directory.

```bash
cp .env.example .env                          # set USERDIR and your domain
docker compose -f compose.ghcr.yaml up -d     # published image
# or
docker compose up -d                          # build locally
```

Then open `https://pi.notato.xyz` (or your own domain) and **pair your phone
once** — writes need a paired device:

```bash
docker exec -it collie collie pair     # prints an 8-character code, valid 10 minutes
```

Enter that code in Collie under **Settings → System → Paired devices**.

---

## What runs inside

| Process | Role |
| --- | --- |
| `herdr server` | The headless multiplexer. Owns the panes and the agents running in them. Started by the entrypoint, which waits for it to answer on the socket API before starting the bridge. Its log is `~/.config/herdr/herdr-server.log` (the entrypoint's own `~/.herdr/server.log` holds just its startup banner). |
| `collie _exec-bridge` | Collie's bridge, the container's foreground process. It mirrors herdr's panes to the PWA over HTTP/WebSocket on `8787`. |
| `pi` | On `PATH` in every pane, along with the rest of the image's toolchain. |

The bridge is exactly what Collie's own systemd unit starts
(`ExecStart=<root>/bin/collie _exec-bridge --instance <name>`), so it is pinned
two ways: the build fails if that command ever disappears from the binary, and CI
boots the container and requires the bridge to come up healthy.

## The persistence model

Everything that must survive a rebuild, a `docker compose down`, or a restart
lives in two mounts:

| Mount | Env | Holds |
| --- | --- | --- |
| `/data/home` | `HOME` | `~/.herdr` (herdr's state, snapshots, worktrees), `~/.config/herdr`, Collie's install root `~/.local/share/collie`, `~/.config/collie` (`.env`, `config.toml`, pairing), `~/.local/state/collie`, `~/.npm` cache, `~/.local/bin` (`pip --user`, `uv`, `pipx`, the `herdr` binary), `~/.cargo`, `~/go`, `~/.bun` |
| `/data/agent` | `PI_CODING_AGENT_DIR` | pi's config, API keys, sessions, packages/extensions, `skills/`, and its own `bin/` |
| `/data/npm` | `NPM_CONFIG_PREFIX` | every `npm install -g <tool>` the agent performs (never the apps — see below) |
| `/workspace` | `PI_WORKSPACE_DIR` | the agent's project files |

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

All of those directories are already on `PATH` — for the bridge process **and**
for the panes Collie shows (the entrypoint also writes
`/etc/profile.d/pi-paths.sh`). `apt-get install` writes to the container
filesystem, not the volume: it survives a plain restart but is gone the next time
the container is recreated, and it is not in a `/data` backup. Use it for one-off
system packages only, or add the package to the `Dockerfile`.

The image ships the C/C++ toolchain (`python3`, `make`, `g++`) on purpose: many
npm packages with native bindings compile on install. The PEP 668 "externally
managed" marker is removed so `pip install --user` works — the toolchains that are
*not* built in (`uv`, `pipx`, `cargo`, `go`, `bun`) still install into `$HOME` and
persist, because `HOME` is on the volume.

### Herdr and Collie live in the volume

The two apps are **seeded from the image into `/data/home` on first start**, not
installed into `/data` at build time and not symlinked out of the image:

- an empty volume boots a complete, working stack with no network access;
- `herdr update` and `collie update` write into the volume, so a self-update
  survives a restart **and** a container recreate (`docker compose down && up`);
- the entrypoint never overwrites an existing install, so an image rebuild cannot
  clobber a version you updated to;
- `collie` on `PATH` is a small wrapper that resolves the install root at runtime
  (`$COLLIE_DIR`, default `~/.local/share/collie`), which is what makes those
  updates land in the volume rather than in an image layer.

The trade-off is deliberate and worth knowing: after a self-update, the volume
copy and the image's seed can differ, and the volume wins. To go back to the
version baked into the image, remove the install and restart:

```bash
rm -rf /data/home/.local/share/collie    # Collie
rm -f  /data/home/.local/bin/herdr       # herdr
docker compose restart
```

### The bundled skills

Herdr and Collie are made to be driven by an agent, so the image ships two
skills and publishes both to the agent at startup:

| Skill | Source | Covers |
| --- | --- | --- |
| [`persistent-tool-install`](skills/persistent-tool-install/SKILL.md) | this repo | Which install paths survive a restart, a recreate and a fresh deploy — and which silently do not. |
| `herdr` | generated at build time from `herdr --skill` | Driving panes, tabs, workspaces and the agents inside them, as the installed herdr version documents it (the vendor's own text, so it cannot drift from the binary). |

The entrypoint symlinks each one into `${PI_CODING_AGENT_DIR}/skills/`, where pi
discovers global skills, so:

- they are available out of the box, including to `/skill:herdr` and `/skill:persistent-tool-install`;
- an image rebuild updates them, because the links point into the image, not a copy;
- a skill *you* replace with a real directory of the same name is left untouched.

It covers one gotcha worth repeating: never `npm install -g` the pi CLI — the
image manages it, and the copy would be shadowed by `/usr/local` anyway.

## Migrating from the pi-web-ui image

Nothing in `/data` needs to change: same volume, same `HOME`, same agent dir. The
service was renamed from `pi-web-ui` to `collie`, so let compose remove the old
container on the way in:

```bash
docker compose -f compose.ghcr.yaml up -d --remove-orphans
```

On startup the entrypoint also **removes the app a pre-Dockerfile compose left in
`/data/npm`**:

```
[pi-docker] removing stale pi-web-ui from /data/npm/lib/node_modules (the image provides it now)
[pi-docker] removing dangling /data/npm/bin/pi-web-ui
```

`/data/npm` is reserved for the tools the agent installs, and a leftover copy of
the old web UI there would keep an outdated server around next to the image's own
binaries. The removal is deliberately narrow — only those two package directories
(`pi-web-ui`, `@earendil-works/pi-coding-agent`) and their dangling `bin`
symlinks. Anything else the agent installed into `/data/npm` is left alone, and a
real file you put in `bin/` is never deleted.

It is also guarded: the cleanup only runs when the image's own Collie wrapper is
present at `/usr/local/bin/collie`. Running this entrypoint against a volume where
`/data/npm` holds the *only* install (an older container, a host shell) leaves it
alone instead of deleting the installation you depend on. Override the location
with `PI_IMAGE_PREFIX` if your build puts the app elsewhere.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `COLLIE_PUBLIC_HOSTS` | *(unset)* | Allow-list of hostnames Collie answers on, e.g. `pi.example.com`. Every other `Host` is refused — including a bare IP and the container name — so `http://<server-ip>:8787` looks "down" while the app is fine. |
| `COLLIE_ALLOWED_ORIGINS` | *(unset)* | Origins allowed to use the UI, e.g. `https://pi.example.com`. **Without it, behind a proxy, the UI loads as an empty page.** |
| `COLLIE_PUBLIC_URL` | *(unset)* | Public URL used for generated links (pairing, notifications). |
| `COLLIE_SKIP_SERVE` | `1` | Do not run `tailscale serve`. The reverse proxy is the only front door (the vendor's deployment "Variant C"). |
| `COLLIE_HOST` | `0.0.0.0` | Bind address. Non-loopback needs `COLLIE_ALLOW_NON_LOOPBACK_BIND=1` — see [Reverse proxy](#reverse-proxy). |
| `COLLIE_ALLOW_NON_LOOPBACK_BIND` | `1` | Required for Traefik (a proxy in another container cannot reach this container's `127.0.0.1`). |
| `COLLIE_PORT` | `8787` | HTTP port. |
| `COLLIE_MUX` | `herdr` | Which multiplexer Collie mirrors. Set explicitly: with none set it probes and refuses when it finds zero or several. |
| `COLLIE_TRUSTED_USER_OPTIONAL` | `1` (compose) | Do not require a trusted login header. Behind authentik that header never arrives; writes are authorized by pairing instead. |
| `COLLIE_DIR` | `/data/home/.local/share/collie` | Collie's install root (`current` → `versions/vX.Y.Z`). |
| `COLLIE_CONFIG_DIR` | `/data/home/.config/collie` | `.env`, `config.toml`, pairing state. |
| `COLLIE_STATE_DIR` | `/data/home/.local/state/collie` | Runtime state. |
| `HERDR_INSTALL_DIR` | `/data/home/.local/bin` | Where the `herdr` binary lives. |
| `HERDR_CONFIG_PATH` | `/data/home/.config/herdr/config.toml` | Seeded with `onboarding = false` on first start; yours after that. |
| `HERDR_PROCESS_DETECTION` | `child-groups` | Container runtimes often do not expose the foreground process group herdr's default detection expects. |
| `PI_WORKSPACE_DIR` | `/workspace` | Directory the agent works in. |
| `PI_CODING_AGENT_DIR` | `/data/agent` | pi config, sessions, API keys. |
| `NPM_CONFIG_PREFIX` | `/data/npm` | Global npm prefix — the persisted tool directory. |
| `HOME` | `/data/home` | Persisted home for the agent, its tools and both apps. |

Everything above is an environment variable, so anything the vendors document as
configurable can also go in `compose.ghcr.yaml`.

### Pairing a device

Collie authorizes writes per device, and pairing is the credential:

```bash
docker exec -it collie collie pair
```

It prints an 8-character code valid for 10 minutes; enter it in the PWA under
**Settings → System → Paired devices**. The paired-device list lives in
`COLLIE_CONFIG_DIR`, so it is part of your `/data` backup — restore the volume and
your phone stays paired. To start over, unpair in the UI and pair again.

`authentik@file` in the Traefik labels is the *door*; pairing is what makes a
browser allowed to *write*. Both are in play, which is why
`COLLIE_TRUSTED_USER_OPTIONAL` is set: Collie would otherwise wait for a trusted
login header that authentik does not send.

### Versions

Everything is installed at build time and can be pinned:

```bash
docker build \
  --build-arg COLLIE_VERSION=v1.16.2 \
  --build-arg HERDR_VERSION=0.9.3 \
  --build-arg PI_CODING_AGENT_VERSION=0.85.1 \
  --build-arg NODE_VERSION=26 \
  -t pi-docker .
```

`COLLIE_VERSION` and `HERDR_VERSION` default to `latest`, which uses each
vendor's own installer and verifies the release checksum
(`herdr.dev/latest.json`, Collie's `.sha256` asset). With an explicit version the
build *asserts* it got that release: the installers always fetch latest, so a
build that silently moved past your pin fails instead of shipping something you
did not ask for.

`NODE_VERSION` picks the `node:<major>-bookworm-slim` base and defaults to `26`
(current LTS); `24` is also supported. CI builds both on every change.

## Reverse proxy

The compose files carry the Traefik labels used in production
(`pi.notato.xyz` + the `authentik@file` middleware). To use your own hostname,
change the Traefik `Host(...)` rule **and** `COLLIE_PUBLIC_HOSTS` /
`COLLIE_ALLOWED_ORIGINS` / `COLLIE_PUBLIC_URL` to match.

Do **not** publish the port. Traefik reaches the container over the docker
network, and `-p 8787:8787` only invites the request Collie refuses (see the
empty-list case below). The compose files leave `ports:` out for this reason.

One deviation from Collie's documented proxy recipes is unavoidable here: they
assume a proxy on the same host (loopback) or `network_mode: host`, and warn that
"inside a container 127.0.0.1 is the container, not your host". A proxy in a
*sibling* container cannot reach this container's loopback, so the image binds
`0.0.0.0` with `COLLIE_ALLOW_NON_LOOPBACK_BIND=1` — Collie refuses a non-loopback
bind unless asked explicitly, which is exactly the opt-in. The cost is that
anything inside the container can reach the port; here that is root and nothing
else. If your proxy runs on the host, drop both variables to stay loopback-only.

## Health

The image declares a healthcheck against `GET /api/health`:

```bash
docker inspect --format '{{.State.Health.Status}}' collie
```

The probe connects to loopback but sends a `Host` header taken from the **first
entry of `COLLIE_PUBLIC_HOSTS`**. Under a strict host allow-list the loopback
host is refused, so a plain `127.0.0.1` probe would fail forever and the container
would sit at `unhealthy` while serving perfectly well — that was the v0.1.0 bug,
and it is why `fetch()` is not used (undici drops a `Host` you set by hand). The
same rule applies to your own checks:

```bash
# allowed host -> 200, a stranger host -> refused (both expected)
curl -s -o /dev/null -w 'allowed  %{http_code}\n' -H 'Host: pi.notato.xyz' http://127.0.0.1:8787/api/health
curl -s -o /dev/null -w 'stranger %{http_code}\n' -H 'Host: nope.example'   http://127.0.0.1:8787/api/health
```

`/api/health` is unauthenticated on purpose (it exposes no secrets), so it works
regardless of pairing.

## Updating

Two things can update, and they are independent:

```bash
docker compose pull && docker compose up -d     # image: pi CLI, seeds, base image
docker compose up -d --build                    # local build instead of pull
```

The apps update themselves, and those updates persist:

```bash
docker exec -it collie collie update
docker exec -it collie collie update --rollback   # previous version
docker exec -it collie herdr update               # inside a pane, or:
docker exec -it collie /data/home/.local/bin/herdr update
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
`data/pi/workspace` are back in place. Collie's pairing and herdr's sessions come
back with it.

## CI & releases

| Workflow | Trigger | Does |
| --- | --- | --- |
| `.github/workflows/ci.yml` | push to `main`, every PR | Builds the image for `linux/amd64` on **Node 24 and 26**, smoke-tests that `collie`, `herdr` and `pi` are on `PATH` and run, that the apps were seeded into the volume as real copies, that the bundled skill is discoverable, that a strict host allow-list still yields a **healthy** container with herdr's server reachable and the bridge running, that the host guard answers only the allowed host, that the entrypoint cleans up migrated installs without reseeding, and validates both compose files. |
| `.github/workflows/release.yml` | push to `main`, manual dispatch | Computes the next semver tag from conventional commits, builds and pushes a multi-arch (`amd64`/`arm64`) image to GHCR, creates a GitHub Release. |

Commits are classified the usual way: `feat!:`/`BREAKING CHANGE` → major,
`feat:` → minor, anything else → patch. Manual runs choose the bump.

## Run the published image (GHCR)

The image is published by the Release workflow to
**`ghcr.io/ksmarty/pi-docker`**, tagged with a semver version and `latest`.

```bash
cp .env.example .env      # set USERDIR (and your domain)
docker compose -f compose.ghcr.yaml up -d
```

The GHCR package is public, so `docker pull` needs no authentication; make it
private in the package settings if you would rather it were not.

## Plain `docker run`

```bash
docker run -d --init --name collie \
  -v "$PWD/data:/data" \
  -v "$PWD/workspace:/workspace" \
  -p 127.0.0.1:8787:8787 \
  pi-docker
```

This is the **direct-access** form: no host allow-list, so loopback requests are
accepted. To put it behind a proxy on a public hostname, drop `-p` and set the
allow-list instead:

```bash
docker run -d --init --name collie \
  -v "$PWD/data:/data" -v "$PWD/workspace:/workspace" \
  -e COLLIE_PUBLIC_HOSTS=pi.example.com \
  -e COLLIE_ALLOWED_ORIGINS=https://pi.example.com \
  -e COLLIE_PUBLIC_URL=https://pi.example.com \
  pi-docker
```

`--init` is recommended (the image runs the bridge as the main process while
herdr's server runs beside it, and the panes spawn shell/agent children).
Passing a command other than the default `serve` skips the bridge and runs that
command instead, which is how the CI tests get a shell through the real
entrypoint:

```bash
docker run --rm -it pi-docker bash
```

## Notes

- The container runs as **root** by design: the agent installs system packages
  and writes into host bind mounts. To run unprivileged, add `user: "1000:1000"`
  (or similar) **and** `chown` the host directories to that uid.
- The C/C++ toolchain is intentionally kept in the final image so the agent can
  build native modules; this trades some image size for a working `npm i -g`.
- **Panes survive a restart; running agents do not.** herdr restores the layout
  from its session snapshot when the server restarts, and resumes the agents in
  those panes only if you ask it to, in
  `~/.config/herdr/config.toml`:

  ```toml
  [session]
  resume_agents_on_restore = true
  ```

- **The container serves nothing to an unexpected `Host`.** If the UI seems
  down, the first lines of `docker logs` say what it resolved to — the entrypoint
  prints the binaries it found, the bind address, the host allow-list and the
  origins (`[pi-docker] hosts : ...`). Then ask for the allowed hostname:

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: pi.notato.xyz' http://127.0.0.1:8787/
  ```

  An answer there means the app is up and the host allow-list is doing its job.
- An **empty page** with a 200 response is the origin allow-list, not a crash:
  set `COLLIE_ALLOWED_ORIGINS` to the URL you actually open.

## Repository layout

```
Dockerfile              single-stage image (NODE_VERSION, default node:26-bookworm-slim)
docker-entrypoint.sh    persistent dirs, seeds the apps, cleans migrated installs, starts herdr, execs the bridge
config/                 herdr config seeded on first start
scripts/               shell tests CI runs against the built image (smoke, healthcheck, host guard, cleanup)
skills/                 agent skills baked into the image (symlinked into the agent dir)
docker-compose.yml      local build
compose.ghcr.yaml       published image (Traefik ready)
.env.example            USERDIR / host / origin
.github/workflows/      CI + release
```
