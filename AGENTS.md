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
- **Never** move `HOME`, `NPM_CONFIG_PREFIX` or `PI_CODING_AGENT_DIR` out of
  `/data` — that silently breaks tool persistence, which is the whole point.
- Keep `/data/npm/bin` and the `$HOME`-relative tool bins on `PATH`, both in the
  image `ENV` and in `/etc/profile.d/pi-paths.sh` written by the entrypoint.
- Keep `python3 make g++` in the final image: `node-pty` compiles from source on
  Linux, and the agent may need to build native modules later.

## Dockerfile conventions

- Keep it **single-stage**. The toolchain is a feature of the runtime, not just
  the build — a multi-stage build that strips it breaks runtime installs.
- The app is installed with an explicit `--global` npm install into the image
  prefix, with the npm cache mounted (`--mount=type=cache,target=/root/.npm`).
- Version knobs are `ARG`s (`PI_WEB_UI_VERSION`, `PI_CODING_AGENT_VERSION`,
  `VERSION`, `COMMIT`), defaulting to `latest` / `dev` / `unknown`.
- Comment the *why* for anything non-obvious (the persistence model, the
  toolchain, the health endpoint). Comments here are documentation for whoever
  rebuilds this image in two years.

## Entrypoint conventions

- `docker-entrypoint.sh` only prepares state: `mkdir -p` the persisted dirs,
  export the paths, write `/etc/profile.d/pi-paths.sh`, then `exec "$@"`.
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
- CI builds `linux/amd64` and must keep the smoke test that proves `pi-web-ui`
  and `pi` are on `PATH` and run — a plain `docker build` does not catch a broken
  install.

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
