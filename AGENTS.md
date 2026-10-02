# AGENTS.md

Guidance for agents (and humans) working in **pi-docker** — the container image
for the pi coding agent and pi-web-ui.

## What this repo is

Not an application. It is packaging: a `Dockerfile`, an entrypoint, two compose
files and two GitHub Actions workflows. There is no test suite and no source
code to run locally — the "build" is `docker build` and the "deploy" is a
release workflow.

## The one invariant: persistence

Everything persistent lives under `/data` (one volume) plus `/workspace`:

| Path | Env | Persisted content |
| --- | --- | --- |
| `/data/home` | `HOME` | `~/.pi-web` UI state, npm cache, `~/.local/bin`, `~/.cargo`, `~/go`, `~/.bun` |
| `/data/agent` | `PI_CODING_AGENT_DIR` | pi config, sessions, API keys, packages |
| `/data/npm` | `NPM_CONFIG_PREFIX` | global npm tools the agent installs |
| `/workspace` | `PI_WEB_CWD` | project files |

Any change must keep this true. Concretely:

- **Never** install pi-web-ui or the pi CLI into `/data/npm` at build time — a
  fresh, empty volume would leave the container without its app. They belong in
  the image prefix (`/usr/local`).
- Keep `/usr/local/bin` ahead of `/data/npm/bin` on `PATH`. `PI_WEB_MANAGED=1`
  disables in-app updates by design, so pulling/rebuilding the image is the only
  upgrade path — an older pi-web-ui persisted in `/data/npm` must never shadow
  the baked one.
- **Never** move `HOME`, `NPM_CONFIG_PREFIX` or `PI_CODING_AGENT_DIR` out of
  `/data` — that silently breaks tool persistence, which is the whole point.
- Keep `/data/npm/bin` and the `$HOME`-relative tool bins on `PATH`, both in the
  image `ENV` and in `/etc/profile.d/pi-paths.sh` written by the entrypoint.
- Keep `python3 make g++` in the final image: `node-pty` compiles from source on
  Linux, and the agent may need to build native modules later.
- Keep `python3-pip` and the `rm -f /usr/lib/python3*/EXTERNALLY-MANAGED` line:
  without them `pip install --user`, which the bundled skill documents as a
  persistent install path, refuses to run under PEP 668.
- **Never put the image's own packages in `/data/npm`** — and keep removing them
  if they are there. The entrypoint deletes a migrated `pi-web-ui` /
  `@earendil-works/pi-coding-agent` from the persisted prefix on every start
  (leftovers from the pre-Dockerfile compose). Keep that cleanup *narrow*:
  `/data/npm` is where the agent's own tools live, so only those two package
  directories and dangling `bin` symlinks may ever be touched.

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

## Dockerfile conventions

- Keep it **single-stage**. The toolchain is a feature of the runtime, not just
  the build — a multi-stage build that strips it breaks runtime installs.
- The app is installed with an explicit `--global` npm install into the image
  prefix, with the npm cache mounted (`--mount=type=cache,target=/root/.npm`).
- Version knobs are `ARG`s (`PI_WEB_UI_VERSION`, `PI_CODING_AGENT_VERSION`,
  `NODE_VERSION`, `VERSION`, `COMMIT`), defaulting to `latest` / `26` / `dev` /
  `unknown`.
- `ARG NODE_VERSION` selects the base (`node:${NODE_VERSION}-bookworm-slim`,
  default `26`, `24` also supported). CI builds both, because `node-pty` has no
  Linux prebuild and is compiled from source — a Node bump is exactly the change
  that breaks it silently.
- The `HEALTHCHECK` must send a `Host` header taken from the first entry of
  `PI_WEB_ALLOW_HOSTS` (`127.0.0.1` fallback) using `http.request`. pi-web-ui's
  host guard answers `403 host not allowed` to any Host it does not know — and
  with `PI_WEB_ALLOW_HOSTS` set that includes `127.0.0.1`. `fetch()` cannot set
  the header at all (undici drops it), so a loopback probe without it reports
  `unhealthy` forever while the app serves fine. That was the shipped-in-v0.1.0
  bug; the strict-mode boot is now a CI regression test.
- Comment the *why* for anything non-obvious (the persistence model, the
  toolchain, the health endpoint). Comments here are documentation for whoever
  rebuilds this image in two years.

## Entrypoint conventions

- `docker-entrypoint.sh` only prepares state: `mkdir -p` the persisted dirs,
  symlink the bundled skills, export the paths, write `/etc/profile.d/pi-paths.sh`,
  then `exec "$@"`.
- It must stay idempotent and must not install or download anything at startup.
- Keep the `:-` defaults on every variable — under `set -e`, `mkdir -p ""` kills
  the container.
- Guard the `/etc/profile.d` write on writability so an unprivileged override
  still works.

## Compose conventions (match the sibling repos)

- `docker-compose.yml` builds locally; `compose.ghcr.yaml` pulls the published
  image. Keep them in sync — same env, same volumes, same labels — differing only
  in `build:` vs `image:`.
- Traefik labels are part of the product: `pi.notato.xyz`, `authentik@file`
  middleware, port `8787`. Leave them in place unless asked otherwise.
- **Do not publish `8787`.** Traefik reaches the container over the docker
  network, and a published port only invites the by-IP request the host guard
  refuses with a bare 403 — which reads as "the container never came online".
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
  hangs visible.
- CI builds `linux/amd64` on **both supported Node lines** and must keep the
  smoke test that proves `pi-web-ui` and `pi` are on `PATH` and run — a plain
  `docker build` does not catch a broken install. Three regressions are pinned
  there and should stay: a container booted with a strict host allow-list must
  reach `healthy`; the host guard must answer the allowed host and refuse
  loopback; and the entrypoint must clean migrated app installs without touching
  the agent's own tools.

## Commits and releases

Conventional commits drive the semver bump: `feat!:` / `BREAKING CHANGE` →
major, `feat:` → minor, everything else → patch. Write commit subjects
accordingly; the Release workflow tags and publishes on every push to `main`.

## Verifying a change

There is no local Docker in every environment; when there is:

```bash
docker build -t pi-docker:test .
docker run --rm --entrypoint bash pi-docker:test -lc 'command -v pi-web-ui pi'
docker compose -f docker-compose.yml config >/dev/null
docker compose -f compose.ghcr.yaml config >/dev/null
```

Otherwise rely on CI, and say so rather than claiming a build succeeded.

Without Docker, the host guard can still be exercised against a real pi-web-ui:
run `PI_WEB_ALLOW_HOSTS=x node <install>/dist/server/index.js` and probe with
`http.request` + an explicit `Host` header. `fetch()` will not do — undici drops
the header, so the probe 403s regardless of the server's configuration.
