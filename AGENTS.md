# AGENTS.md

Guidance for agents (and humans) working in **pi-docker** — the container image
for [Herdr](https://herdr.dev), the [Collie PWA](https://colliepwa.dev) and the
pi coding agent.

## What this repo is

Not an application. It is packaging: a `Dockerfile`, an entrypoint, two compose
files, two GitHub Actions workflows, the shell tests CI runs and one agent skill.
There is no test suite and no source code to run locally — the "build" is
`docker build` and the "deploy" is a release workflow. The vendors own the two
apps; this repo only installs them, points them at a volume and keeps them alive.

## The one invariant: persistence

Everything persistent lives under `/data` (one volume) plus `/workspace`:

| Path | Env | Persisted content |
| --- | --- | --- |
| `/data/home` | `HOME` | `~/.herdr` (state, snapshots, worktrees), `~/.config/herdr`, `~/.local/share/collie`, `~/.config/collie` + `~/.local/state/collie` (env, config, pairing), `~/.npm`, `~/.local/bin`, `~/.cargo`, `~/go`, `~/.bun` |
| `/data/agent` | `PI_CODING_AGENT_DIR` | pi config, sessions, API keys, packages, `skills/` |
| `/data/npm` | `NPM_CONFIG_PREFIX` | global npm tools the agent installs |
| `/workspace` | `PI_WORKSPACE_DIR` | project files |

Any change must keep this true. Concretely:

- **Never** install herdr or Collie into `/data` at build time, and never
  symlink them out of the image. They are **seeded from the image into the
  volume** by the entrypoint (copy, only when missing) so that an empty volume
  boots a working stack *and* `herdr update` / `collie update` land in the
  volume, where they survive a restart, a recreate and a fresh deploy.
- **Never** bake the pi CLI (`@earendil-works/pi-coding-agent`) into `/data`
  either — it belongs in the image prefix (`/usr/local`), and the entrypoint
  deletes it from `/data/npm` on every start. `/usr/local/bin` stays ahead of
  `/data/npm/bin` on `PATH` so a stale volume copy can never shadow the baked
  one.
- **Never** move `HOME`, `NPM_CONFIG_PREFIX` or `PI_CODING_AGENT_DIR` out of
  `/data` — that silently breaks tool persistence, which is the whole point.
- Keep `/data/npm/bin` and the `$HOME`-relative tool bins on `PATH`, both in the
  image `ENV` and in `/etc/profile.d/pi-paths.sh` written by the entrypoint —
  the panes Collie shows read the profile, the bridge reads the process env.
- Keep `python3 make g++` in the final image: native npm modules compile on
  install, and the agent may need to build more later.
- Keep `python3-pip` and the `rm -f /usr/lib/python3*/EXTERNALLY-MANAGED` line:
  without them `pip install --user`, which the bundled skill documents as a
  persistent install path, refuses to run under PEP 668.
- **Never put the image's own packages in `/data/npm`** — and keep removing them
  if they are there. `/data/npm` is where the agent's own tools live; only the
  two migrated package directories and dangling `bin` symlinks may be touched.

## The two apps, and why they are seeded not installed

`COLLIE_VERSION` / `HERDR_VERSION` default to `latest`; the vendors' installers
verify the release checksum, and with an explicit version the build asserts the
installed version matches the pin (`Dockerfile`'s post-check) rather than
silently moving past it.

- Collie's root is versioned (`…/collie/current` → `versions/vX.Y.Z`) and
  selected at runtime by our `/usr/local/bin/collie` wrapper, which resolves
  `$COLLIE_DIR` (default `~/.local/share/collie`). That indirection is what
  makes `collie update` persistent — do not replace it with a real binary path.
- herdr is a static binary in `$HOME/.local/bin`.
- Collie supports exactly one bridge today, and the container starts **herdr** —
  the whole image is built around that pairing. `COLLIE_MUX=herdr` is set
  explicitly because with nothing set Collie probes and refuses when it finds
  zero or several multiplexers.
- The bridge is started as `collie _exec-bridge --instance <name>`, mirroring
  Collie's own systemd unit. It is an **internal verb**: the build greps the
  binary for it and CI boots the container and requires the bridge to come up, so
  a vendor rename fails the build or the test instead of shipping silently.
- Collie's own proxy recipes assume the proxy is on the same host (loopback or
  `network_mode: host`); a proxy in a sibling container cannot reach this
  container's `127.0.0.1`. Hence `COLLIE_ALLOW_NON_LOOPBACK_BIND=1` and a
  `0.0.0.0` bind, which Collie refuses unless explicitly asked. This deviation is
  documented in the README; keep the two in sync.

## Bundled skills

`skills/<name>/SKILL.md` in this repo is baked into the image at
`/opt/pi-docker/skills/`, and `docker-entrypoint.sh` symlinks each skill into
`${PI_CODING_AGENT_DIR}/skills/` — the location pi scans for global skills.

Rules that keep this working:

- **Symlink, never copy.** The image must stay the single source of truth so a
  rebuild updates the skill; a copy into the volume would freeze at first run.
- **Never re-link over an existing path.** The link is created only when nothing
  is there, so a user who replaced a skill with their own real directory keeps it.
- **Never add a blanket `*.md` to `.dockerignore`** — it would drop
  `skills/<name>/SKILL.md` from the build context.
- Skills must keep valid frontmatter (`name` + non-empty `description`), or pi
  silently ignores them. CI asserts discovery through pi's own loader, because a
  file sitting in the image is not proof that the agent can see it.
- Document the *image's actual layout* in a skill, and update the skill in the
  same commit as any change to paths, env vars or the persistence model. A stale
  skill actively misleads the agent.
- `skills/herdr/SKILL.md` is **generated at build time** from
  `/opt/pi-docker/seed/bin/herdr --skill`. Never vendor a copy into the repo: the
  vendor's text is version-matched to the binary, and a hand-copied snapshot
  would describe a command surface the image no longer has. It lands in the same
  directory as the hand-written skills so the entrypoint's existing loop needs no
  special case — and CI asserts it is discoverable, frontmatter and all.

## Dockerfile conventions

- Keep it **single-stage**. The toolchain is a feature of the runtime, not just
  the build — a multi-stage build that strips it breaks runtime installs.
- `ARG NODE_VERSION` selects the base (`node:${NODE_VERSION}-bookworm-slim`,
  default `26`, `24` also supported). CI builds both, because the base line and
  the vendors' prebuilt binaries move independently.
- Version knobs are `ARG`s (`COLLIE_VERSION`, `HERDR_VERSION`,
  `PI_CODING_AGENT_VERSION`, `NODE_VERSION`, `VERSION`, `COMMIT`), defaulting to
  `latest` / `latest` / `latest` / `26` / `dev` / `unknown`. They are ordinary env
  vars by design, not image-managed state: the agents can set anything the
  vendors document.
- Install the pi CLI with an explicit `--global` npm install into the image
  prefix, with the npm cache mounted (`--mount=type=cache,target=/root/.npm`).
- Both vendor installers run in one layer with their scratch files removed, so
  no installer script or archive is left in the image, and the `herdr` binary is
  smoke-run at build time.
- The `HEALTHCHECK` must send a `Host` header taken from the first entry of
  `COLLIE_PUBLIC_HOSTS` (`127.0.0.1` fallback) using `http.request`. Under a
  strict host allow-list the loopback host is refused, so a plain loopback probe
  reports `unhealthy` forever while the app serves fine. `fetch()` cannot set the
  header at all — undici drops it. That was the shipped-in-v0.2.0 bug; the
  strict-mode boot is a CI regression test. Give it a long `start-period`: a cold
  boot syncs the plugin catalog before the server binds.
- Comment the *why* for anything non-obvious (the persistence model, the
  seeding, the toolchain, the health endpoint). Comments here are documentation
  for whoever rebuilds this image in two years.

## Entrypoint conventions

- `docker-entrypoint.sh` only prepares state: `mkdir -p` the persisted dirs,
  seed the two apps when missing, symlink the bundled skills, export the paths,
  write `/etc/profile.d/pi-paths.sh`, start `herdr server` in the background, then
  `exec "$@"` (default `serve` → the Collie bridge).
- It must stay idempotent and must not install or download anything at startup.
- Seed with `cp -a "${APP_SEED}/collie/." "${COLLIE_DIR}/"`. The trailing `/.`
  is load-bearing: the entrypoint `mkdir -p`s every destination first, and
  `cp -a src dst` where `dst` already exists copies *into* it (`dst/src/...`).
  That silently leaves a volume with no `${COLLIE_DIR}/current`, so the `collie`
  shim falls back to the image seed and `collie update` writes into a tree
  nothing reads. Shipped in v1.0.0; CI now asserts
  `${HOME}/.local/share/collie/current/bin/collie` is executable to catch it, and
  a restart self-heals a volume seeded by the broken version.
- **Readiness of herdr's server comes from the socket API** (`herdr api
  snapshot`), never from `herdr session list`. `session list` is a *local*
  command: it reads session directories and exits 0 with `"running": false` when
  no server exists, so a loop built on it declares the server ready on the first
  tick and the bridge is handed a socket that is not there yet. `api snapshot`
  goes over the socket and exits non-zero with `server_not_running` until it is.
  CI pins this, because the failure looks like "Collie shows no panes" rather
  than like a probe bug.
- Vendor CLI exit codes are easy to measure wrongly — `cmd | head -3; echo $?`
  reports `head`'s status, not `cmd`'s. Every probe in this repo was checked
  both ways (server up and server down) before being trusted.
- Keep the `:-` defaults on every variable — under `set -e`, `mkdir -p ""` kills
  the container.
- Guard the `/etc/profile.d` write on writability so an unprivileged override
  still works.
- The migrated-install cleanup must never delete the only install on the box: it
  runs only when the image's own Collie wrapper is present
  (`${PI_IMAGE_PREFIX:-/usr/local}/bin/collie`). Invoking this entrypoint outside
  the image — a host shell, or a container that shares the volume — has to be a
  no-op. (This is not theoretical: running it against a live pre-Dockerfile
  install deletes the running app's files.)

## Compose conventions (match the sibling repos)

- `docker-compose.yml` builds locally; `compose.ghcr.yaml` pulls the published
  image. Keep them in sync — same env, same volumes, same labels — differing only
  in `build:` vs `image:`.
- Traefik labels are part of the product: `pi.notato.xyz`, `authentik@file`
  middleware, port `8787`. Leave them in place unless asked otherwise, and keep
  them consistent with `COLLIE_PUBLIC_HOSTS` / `COLLIE_ALLOWED_ORIGINS`.
- **Do not publish `8787`.** Traefik reaches the container over the docker
  network, and a published port only invites the request the host guard refuses
  with a bare 403 — which reads as "the container never came online".
- `COLLIE_MUX=herdr` and `COLLIE_TRUSTED_USER_OPTIONAL=1` are both required
  here: the first pins the multiplexer, the second stops Collie demanding a
  trusted login header that authentik never sends.
- `init: true` and `restart: unless-stopped` are required.
- `user: "0:0"` is intentional (see README).

## Workflow conventions

- Reuse the pinned action versions already used across these repos:
  `actions/checkout@v7`, `docker/setup-qemu-action@v4`,
  `docker/setup-buildx-action@v4`, `docker/login-action@v4`,
  `docker/metadata-action@v6`, `docker/build-push-action@v7`,
  `softprops/action-gh-release@v3`.
- Write versions natively (`git describe` + conventional-commit parsing) — do
  not add a third-party version-bump action.
- Release publishes `linux/amd64` **and** `linux/arm64` to GHCR, with
  `provenance: false`, `sbom: false` and `cache-to: type=gha,mode=min` (the
  `mode=max` export has hung releases before). `BUILDKIT_PROGRESS: plain` keeps
  hangs visible, and each job sets `timeout-minutes` so a stuck leg fails instead
  of burning GitHub's 6h default.
- CI builds `linux/amd64` on **both supported Node lines** and must keep the
  smoke test that proves `collie`, `herdr` and `pi` are on `PATH` and run — a
  plain `docker build` does not catch a broken install. Four regressions are
  pinned there and should stay: a container booted with a strict host allow-list
  must reach `healthy`; the host guard must answer the allowed host and refuse
  loopback; the entrypoint must clean migrated app installs without touching the
  agent's own tools *or* reseeding the current apps; and both apps must be real
  copies inside the volume, so `herdr update` / `collie update` persist.
- The image-facing tests live in `scripts/*.sh` and CI pipes each one in with
  `bash -lc "$(cat scripts/<name>.sh)"` instead of inlining it. Inlining means the
  script has to survive `docker run … bash -lc '<script>'`, and one single quote
  inside it closes that outer quoting: the script is silently truncated and its
  tail arrives as extra `docker` arguments (seen as a bare "exit code 2" with no
  other clue). A file cannot be mangled that way.
- Test scripts default to the image layout but must keep their paths overridable
  (`NPM_CONFIG_PREFIX`, `ENTRYPOINT`, `PI_IMAGE_PREFIX`, `COLLIE_DIR`,
  `HERDR_INSTALL_DIR`), so they can be exercised against a throwaway prefix
  without touching a real `/data`.
- On failure a test script prints the container logs, `docker inspect` state and
  docker's own healthcheck probe output *and* re-emits them as `::error::`
  annotations. Job logs need repo admin rights over the API; annotations are
  readable without them, so the reason survives.
- Every test script therefore runs `set -eEuo pipefail` with an `ERR` trap that
  annotates the failing line and command. Most assertions are bare `test` /
  `docker exec` lines that never reach a `fail()` helper and, under plain
  `set -e`, exit silently — that is how the first Collie smoke failure arrived as
  "exit code 1" with nothing else. `-E` is required, or the trap does not fire
  inside functions.
- When you add an assertion, check it asserts the thing you mean. That same smoke
  test also asserted `command -v collie` was a symlink resolving into the volume,
  when the image deliberately puts a *shim script* there and the volume
  resolution happens at exec time — the test was wrong, not the image, and it
  cost a CI round trip to find out.

## Commits and releases

Conventional commits drive the semver bump: `feat!:` / `BREAKING CHANGE` →
major, `feat:` → minor, everything else → patch. Write commit subjects
accordingly; the Release workflow tags and publishes on every push to `main`.

## Verifying a change

There is no local Docker in every environment; when there is:

```bash
docker build -t pi-docker:test .
docker run --rm --entrypoint bash pi-docker:test -lc 'command -v collie herdr pi'
docker compose -f docker-compose.yml config >/dev/null
docker compose -f compose.ghcr.yaml config >/dev/null
```

Otherwise rely on CI, and say so rather than claiming a build succeeded.

Without Docker, the host guard and the health probe can still be exercised
against a real Collie: run `bash -lc "$(cat scripts/healthcheck-test.sh)"` with
`SKIP_BOOT=1` and a `COLLIE_DIR` pointing at an extracted release, or start the
bridge by hand with `COLLIE_PUBLIC_HOSTS=x` and probe with `http.request` plus an
explicit `Host` header. `fetch()` will not do — undici drops the header, so the
probe 403s regardless of the server's configuration.
