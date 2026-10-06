# AGENTS.md

Guidance for agents (and humans) working in **pi-docker** — the container image
for [Herdr](https://herdr.dev), the **herdr web UI** plugin that serves it as a
PWA, and the pi coding agent.

## What this repo is

Not an application. It is packaging: a `Dockerfile`, an entrypoint, two compose
files, two GitHub Actions workflows, the shell tests CI runs and one hand-written
agent skill. There is no test suite and no source code to run locally — the
"build" is `docker build` and the "deploy" is a release workflow. The vendors own
the apps; this repo only installs them, points them at a volume and keeps them
alive.

The stack is exactly three things, and the container runs all of them:

| Component | Where it comes from | What it is |
| --- | --- | --- |
| `herdr` | herdr.dev release, a static binary | the headless multiplexer/server; owns the sockets, panes and worktrees |
| `devswha.herdr-web-ui` | a herdr **plugin** (`herdr plugin install`) | the web UI / PWA a phone or browser opens |
| `pi` | npm `@earendil-works/pi-coding-agent` | the coding agent the panes run |

The web UI is a plugin, not a separate app: it is started *by* herdr, its settings
come from herdr's plugin config directory, and it is useless without herdr's
server up. That coupling is why the image seeds both and why the tests assert the
server, the plugin and the served UI separately.

## The one invariant: persistence

Everything persistent lives under `/data` (one volume) plus `/workspace`:

| Path | Env | Persisted content |
| --- | --- | --- |
| `/data/home` | `HOME` | `~/.config/herdr` (config, `plugins.json`, the plugin checkout and its `config/<plugin-id>/env`), `~/.local/share/herdr` (state, snapshots, worktrees), `~/.local/bin` (the seeded herdr), `~/.npm`, `~/.cargo`, `~/go`, `~/.bun` |
| `/data/agent` | `PI_CODING_AGENT_DIR` | pi config, sessions, API keys, packages, `skills/` |
| `/data/npm` | `NPM_CONFIG_PREFIX` | global npm tools the agent installs |
| `/workspace` | `PI_WORKSPACE_DIR` | project files |

Any change must keep this true. Concretely:

- **Never** install herdr or the web UI plugin into `/data` at build time, and
  never symlink them out of the image. They are **seeded from the image into the
  volume** by the entrypoint (copy, only when missing) so that an empty volume
  boots a working stack *and* `herdr update` / `herdr plugin update` land in the
  volume, where they survive a restart, a recreate and a fresh deploy.
- **Never** let the seeding overwrite something that is already in the volume.
  The rule is "copy only when the destination is missing" — an unconditional copy
  silently reverts every update on the next start, and the plugin still boots, so
  the only symptom is a user saying "my update keeps undoing itself".
- **Never** bake the pi CLI (`@earendil-works/pi-coding-agent`) or bun into
  `/data` — they belong in the image prefix (`/usr/local`), and the entrypoint
  deletes the pi CLI from `/data/npm` on every start. `/usr/local/bin` stays ahead
  of `/data/npm/bin` on `PATH` so a stale volume copy can never shadow the baked
  one.
- **Never** move `HOME`, `NPM_CONFIG_PREFIX` or `PI_CODING_AGENT_DIR` out of
  `/data` — that silently breaks tool persistence, which is the whole point.
- Keep `/data/npm/bin` and the `$HOME`-relative tool bins on `PATH`, both in the
  image `ENV` and in `/etc/profile.d/pi-paths.sh` written by the entrypoint — the
  panes the web UI shows read the profile, the plugin inherits the process env.
- Keep `python3 make g++ rg git` in the final image: native npm modules compile on
  install, the agent may need to build more later, and `rg` is a runtime
  prerequisite of the plugin itself.
- Keep `python3-pip` and the `rm -f /usr/lib/python3*/EXTERNALLY-MANAGED` line:
  without them `pip install --user`, which the bundled skill documents as a
  persistent install path, refuses to run under PEP 668.
- **Never put the image's own packages in `/data/npm`** — and keep removing them
  if they are there. `/data/npm` is where the agent's own tools live; only the
  migrated package directories and dangling `bin` symlinks may be touched.

## Seeding, and the plugin registry

The entrypoint's job at start is *state preparation*, and the ordering matters:

1. `mkdir -p` every persisted directory (with `:-` defaults on every variable —
   under `set -e`, `mkdir -p ""` kills the container).
2. Seed herdr's binary, `~/.config/herdr/config.toml` and the whole plugin
   checkout **only when missing**.
3. **Repair the plugin registry paths.** `~/.config/herdr/plugins.json` records
   three absolute paths per entry (`plugin_root`, `manifest_path`,
   `source.managed_path`). The image's copy of that registry points into
   `/opt/pi-docker/seed/...`; before herdr starts, those paths are rewritten to
   the volume's copies. Without this the plugin is "installed" but its manifest
   lives in the image, so `herdr plugin update` writes somewhere a restart throws
   away — and a build host path that does not exist in the container makes the
   plugin fail to load at all.
4. Seed the plugin's settings file
   (`~/.config/herdr/plugins/config/devswha.herdr-web-ui/env`) from
   `HERDR_WEB_HOST` / `HERDR_WEB_PORT` / `HERDR_WEB_TOKEN` when it does not exist.
5. Clean the migrated npm installs, symlink the bundled skills, write the
   `profile.d` paths, start `herdr server` in the background, wait for it, then
   `exec "$@"` (default `serve` = run the plugin in the foreground).

Two traps, both load-bearing:

- **The plugin reads HOST/PORT/TOKEN from that env file, not from the container
  environment, and the file wins.** So the file — not the process env — is what
  the UI actually binds. Anything that reports or probes the bind (the banner, the
  readiness check, the `HEALTHCHECK`) must resolve the effective value from the
  file, or it will confidently describe a port nothing is listening on. This is
  the "the log says one thing, the app does another" failure mode that makes an
  unreachable UI unreadable.
- **Never re-`cp -a` a seeded tree over an existing one.** `cp -a src dst` where
  `dst` exists copies *into* it (`dst/src/...`), which is how a previous version of
  this repo produced a volume with no working install while reporting success.
  Seed with `mkdir -p dst` plus `cp -a src/. dst/` if you must, and prefer
  `install -m 0755` / explicit per-file copies.

## Readiness: the socket API, never `session list`

Wait for herdr with `herdr api snapshot`. That goes over the socket and exits
non-zero with `server_not_running` until the server is really listening.
`herdr session list` is a *local* command: it reads session directories and exits
0 with `"running": false` when no server exists, so a probe built on it declares
the server ready on the first tick and hands the plugin a socket that is not there
yet. CI pins this, because the failure looks like "the web UI shows no panes"
rather than like a probe bug.

Vendor CLI exit codes are easy to measure wrongly — `cmd | head -3; echo $?`
reports `head`'s status, not `cmd`'s. Every probe in this repo was checked both
ways (server up and server down) before being trusted.

## The healthcheck, and the probe lesson

The `HEALTHCHECK` probes the plugin's own `GET /api/health` on loopback and
requires **`"ok":true`**, not merely a 200. Measured contract of plugin 0.3.50:

| Request | Result |
| --- | --- |
| `GET /api/health` | 200 `{"ok":true,"herdr":{...},"auth":{...},"web_ui":{"boot_id":...}}` |
| `GET /api/health` with a foreign `Host` | 200, identical body — **there is no host allow-list** |
| `GET /api/health` with a token configured | 200, unauthenticated by design (this is why the route is the probe) |
| `GET /` | 200, the PWA shell (it asks to pair rather than refusing) |
| `GET /health` (no `/api` prefix) | 200 **HTML** — the SPA, not an endpoint. Never probe it |

`ok:true` is the vendor's own liveness field and it covers both halves: the body
reports herdr's version/link *and* the UI's `boot_id`, so a plugin whose socket
link died cannot look healthy while the server is fine.

The lesson from the outage that started this repo: the container was serving while
docker reported `unhealthy` forever, because the probe sent a `Host` header the
then-shipped app refused. Two rules survive that:

- **A probe must assert the contract the app actually offers.** Do not send a
  header, and do not claim a guard, that the shipped version does not have —
  asserting a behaviour nobody implemented is the same class of bug, mirrored. If
  a future plugin grows a host allow-list, this file, the healthcheck and
  `scripts/ci-web-ui.sh` all change together, and the test already fails loudly
  with that instruction when a foreign `Host` stops being accepted.
- **`fetch()`/undici cannot set a `Host` header at all** — it drops it silently —
  so a probe written with it tests something other than what it claims. Use
  `http.request` / `http.get` from `node`.
- On failure, print the status and body to stderr: it lands in `docker inspect`'s
  health log, and an `unhealthy` with no reason *was* the original complaint. Give
  the check a long `start-period` (90s): a cold boot seeds herdr, installs the
  plugin's dependencies and syncs before anything binds, and
  `docker compose up --wait` treats an unhealthy container as a failed start.

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
  vendor's text is version-matched to the binary, and a hand-copied snapshot would
  describe a command surface the image no longer has. It lands in the same
  directory as the hand-written skills so the entrypoint's existing loop needs no
  special case — and CI asserts it is discoverable, frontmatter and all.

## Dockerfile conventions

- Keep it **single-stage**. The toolchain is a feature of the runtime, not just
  the build — a multi-stage build that strips it breaks runtime installs.
- `ARG NODE_VERSION` selects the base (`node:${NODE_VERSION}-bookworm-slim`,
  default `26`, `24` also supported). CI builds both, because the base line and
  the vendors' prebuilt binaries move independently.
- Version knobs are `ARG`s (`HERDR_VERSION`, `HERDR_WEB_UI_VERSION`,
  `PI_CODING_AGENT_VERSION`, `NODE_VERSION`, `VERSION`, `COMMIT`), defaulting to
  `latest` / `v0.3.50` / `latest` / `26` / `dev` / `unknown`. They are ordinary env
  vars by design, not image-managed state: the agents can set anything the vendors
  document. `HERDR_WEB_UI_VERSION` is pinned rather than `latest` on purpose — the
  plugin's version is what the HTTP contract above was measured against.
- Install the pi CLI with an explicit `--global` npm install into the image
  prefix, with the npm cache mounted (`--mount=type=cache,target=/root/.npm`).
- Bake the plugin **into the seed in the same build**, by running the vendor's own
  installer (`herdr plugin install`) against the staged `HOME` and then asserting
  the result (`herdr plugin list` shows it enabled, and `jq` proves the registry's
  recorded paths all live under the seed). A build that records the build host's
  own `HOME` would ship a plugin that cannot load — assert it, do not hope.
- Remove the installer's scratch files in the same layer, and smoke-run the
  seeded binaries at build time. An explicit `HERDR_VERSION` is asserted against
  what landed rather than silently moving past the pin.
- Seed paths are fixed and deterministic (`/opt/pi-docker/seed/...`) because the
  registry bakes absolute paths; the entrypoint rewrites them to the volume.
- Comment the *why* for anything non-obvious (the persistence model, the seeding,
  the toolchain, the health endpoint). Comments here are documentation for whoever
  rebuilds this image in two years.

## Entrypoint conventions

- It only prepares state — `mkdir -p`, seed what is missing, repair the registry,
  symlink skills, export paths, write `/etc/profile.d/pi-paths.sh`, start
  `herdr server`, wait for the socket, then `exec "$@"` (default `serve`). It must
  stay idempotent and must not install or download anything at startup.
- That preparation runs for **every** command, not only the default `serve`. The
  container is a herdr host first, and CI runs other commands in it (a smoke
  script, a shell) that assert the socket, the plugin registration and the served
  UI. Gating the server on `serve` handed those a container with no server at all,
  and it surfaced as a bare `exit 1` on `herdr api snapshot` in the smoke test
  while the image itself was fine — the default CMD is the *least* tested path,
  because every real test overrides it.
- Keep the `:-` defaults on every variable; guard the `/etc/profile.d` write on
  writability so an unprivileged override still works.
- The migrated-install cleanup must never delete the only install on the box: it
  runs only when the image's own seed is present (`PI_APP_SEED`). Invoking this
  entrypoint outside the image — a host shell, or a container that shares the
  volume — has to be a no-op. (Not theoretical: running it against a live
  pre-Dockerfile install deletes the running app's files.)
- Print the resolved values on every start (binaries found, the *effective* bind,
  whether a token is set, whether the plugin is registered and enabled). The
  original bug report was "it never came online, the logs were unhelpful"; the
  banner exists so that a UI that is unreachable in fact cannot look fine in the
  log. Never print `HERDR_WEB_TOKEN`'s value — report set/unset.
- `PI_QUIET=1` suppresses the banner for tests; the effective-bind resolution
  itself must stay unconditional, because the readiness check uses it.

## Compose conventions (match the sibling repos)

- `docker-compose.yml` builds locally; `compose.ghcr.yaml` pulls the published
  image. Keep them in sync — same env, same volumes, same labels — differing only
  in `build:` vs `image:`.
- Traefik labels are part of the product: `pi.notato.xyz`, `authentik@file`
  middleware, port `7317`. Leave them in place unless asked otherwise.
- **Do not publish `7317`.** Traefik reaches the container over the docker
  network. The plugin has no host allow-list, so a published port puts a UI that
  is trivially reachable from every interface, and the first visitor is the one
  who gets to pair. The authentik middleware is the door, not the port mapping;
  anyone who really wants a published port must set `HERDR_WEB_TOKEN` too.
  `HERDR_WEB_HOST=0.0.0.0` is set explicitly for the proxy in the sibling
  container, which cannot reach this container's `127.0.0.1` (the plugin's own
  default is loopback).
- `init: true` and `restart: unless-stopped` are required.
- `user: "0:0"` is intentional (see README).

## Workflow conventions

- Reuse the pinned action versions already used across these repos:
  `actions/checkout@v7`, `docker/setup-qemu-action@v4`,
  `docker/setup-buildx-action@v4`, `docker/login-action@v4`,
  `docker/metadata-action@v6`, `docker/build-push-action@v7`,
  `softprops/action-gh-release@v3`.
- Write versions natively (`git describe` + conventional-commit parsing) — do not
  add a third-party version-bump action.
- Release publishes `linux/amd64` **and** `linux/arm64` to GHCR, with
  `provenance: false`, `sbom: false` and `cache-to: type=gha,mode=min` (the
  `mode=max` export has hung releases before). `BUILDKIT_PROGRESS: plain` keeps
  hangs visible, and each job sets `timeout-minutes` so a stuck leg fails instead
  of burning GitHub's 6h default.
- CI builds `linux/amd64` on **both supported Node lines** and must keep the smoke
  test that proves `herdr`, `pi` and `bun` are on `PATH` and run — a plain
  `docker build` does not catch a broken install. Five regressions are pinned and
  should stay: a fresh boot with an empty volume reaching `healthy` on its own;
  the UI's served HTTP contract (`scripts/ci-web-ui.sh`, run *with* a token set);
  tools, agent state and app updates surviving both a restart and a recreate; the
  migrated-install cleanup (and its guard, and that it never re-seeds over the
  volume); and the plugin being registered + enabled from the volume with its
  registry paths repaired.
- The image-facing tests live in `scripts/*.sh` and CI pipes each one in with
  `bash -lc "$(cat scripts/<name>.sh)"` instead of inlining it. Inlining means the
  script has to survive `docker run … bash -lc '<script>'`, and one single quote
  inside it closes that outer quoting: the script is silently truncated and its
  tail arrives as extra `docker` arguments (seen as a bare "exit code 2" with no
  other clue). A file cannot be mangled that way.
- Test scripts default to the image layout but must keep their paths overridable
  (`NPM_CONFIG_PREFIX`, `ENTRYPOINT`, `PI_APP_SEED`, `HERDR_INSTALL_DIR`), so they
  can be exercised against a throwaway prefix without touching a real `/data`.
- On failure a test script prints the container logs, `docker inspect` state and
  docker's own healthcheck probe output *and* re-emits them as `::error::`
  annotations. Job logs need repo admin rights over the API; annotations are
  readable without them, so the reason survives. They are also capped and sampled,
  so the reason has to be annotated *before* the context — a dump that puts 25 log
  lines ahead of an `ENOENT` can lose the annotation entirely, which is why the
  scripts have a `dump_logs()` that greps for the error first.
- Every test script therefore runs `set -eEuo pipefail` with an `ERR` trap that
  annotates the failing line and command. Most assertions are bare `test` /
  `docker exec` lines that never reach a `fail()` helper and, under plain
  `set -e`, exit silently — that is how the first smoke failure arrived as "exit
  code 1" with nothing else. `-E` is required, or the trap does not fire inside
  functions.
- When a probe gives up, report *what it observed*, not just that it failed. "The
  UI never answered" hides the difference between still booting, answering 503
  because the socket link died, and not listening at all.
- When you add an assertion, check it asserts the thing you mean. Two real
  examples: a test asserted `command -v collie` was a symlink resolving into the
  volume when the image deliberately puts a *shim script* there (the test was
  wrong, not the image), and a probe built with `${var:+...}` whose `...` contained
  a JS object literal — bash ends that expansion at the first `}`, so the generated
  code carried a stray `;}` and node threw a `SyntaxError` on every run. Both cost
  a CI round trip. Exercise the tricky bit against a fake server locally before
  trusting CI to.

## Commits and releases

Conventional commits drive the semver bump: `feat!:` / `BREAKING CHANGE` → major,
`feat:` → minor, everything else → patch. Write commit subjects accordingly; the
Release workflow tags and publishes on every push to `main`.

## Verifying a change

There is no local Docker in every environment; when there is:

```bash
docker build -t pi-docker:test .
docker run --rm --entrypoint bash pi-docker:test -lc 'command -v herdr pi bun'
docker compose -f docker-compose.yml config >/dev/null
docker compose -f compose.ghcr.yaml config >/dev/null
bash -n docker-entrypoint.sh scripts/*.sh
```

Otherwise rely on CI, and say so rather than claiming a build succeeded.

Without Docker, more is still testable than it looks — and this is how the probe
bugs above were actually found:

- Run the entrypoint directly against a throwaway prefix (`HOME=/tmp/x`,
  `NPM_CONFIG_PREFIX=/tmp/x/npm`, `PI_APP_SEED=/nonexistent`) to exercise the
  seeding and cleanup logic without touching a real `/data`. Keep the seed guard
  intact while doing it.
- Run the shipped `HEALTHCHECK`'s `node -e` body straight from the Dockerfile
  against a locally started plugin (or a fake server that mimics the measured
  contract) and check the env-file port precedence both ways.
- `scripts/ci-web-ui.sh` can be exercised without docker: put a shim named
  `docker` on `PATH` that turns `docker exec -i <name> node -e <code>` into
  `node -e <code>`, point it at a server on the port the script expects, and
  confirm both the passing and the failing paths — the failure messages are part
  of what is being reviewed.
