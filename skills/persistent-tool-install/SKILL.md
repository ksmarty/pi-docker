---
name: persistent-tool-install
description: How to install CLI tools and language runtimes inside this pi-docker container so they survive a restart, image rebuild and `docker compose down`. Use whenever you need a tool that is not already installed (npm packages, pip/pipx/uv tools, cargo binaries, go binaries, bun tools, standalone binaries), whenever you would otherwise reach for `apt-get install`, or whenever you need to check whether an installed tool will actually still be there after a restart. Also covers why pi-web-ui and the pi CLI must never be installed this way.
license: MIT
---

# Installing tools so they persist

This container keeps **everything persistent under `/data`** (plus `/workspace`).
Everything else — `/usr`, `/usr/local`, `/opt`, `/root` — is the container
filesystem, which survives a plain `docker restart` but is **thrown away and
rebuilt from the Dockerfile whenever the container is recreated**: a new image
(`docker compose pull && docker compose up -d`, or `--build`), a
`docker compose down && up`, or a fresh deploy on an empty volume. It is also
absent from a `/data` backup. That single fact decides how to install anything.

You are **root**, so `sudo` is unnecessary (and usually absent).

## The rule

> Install into a directory under `/data`, or the tool is gone the next time the
> container is recreated — image update, `docker compose down && up`, or a fresh
> deploy. A plain `docker restart` alone will not lose it, which is exactly what
> makes the trap easy to fall into.

| Path | On `PATH` | Env that points here | Survives |
| --- | --- | --- | --- |
| `/data/npm/bin` | yes | `NPM_CONFIG_PREFIX=/data/npm` | ✅ restart + recreate |
| `/data/home/.local/bin` | yes | `HOME=/data/home` (`pip --user`, `uv`, `pipx`) | ✅ restart + recreate |
| `/data/home/.cargo/bin` | yes | `CARGO_HOME` default under `$HOME` | ✅ restart + recreate |
| `/data/home/go/bin` | yes | `GOPATH` default under `$HOME` | ✅ restart + recreate |
| `/data/home/.bun/bin` | yes | `BUN_INSTALL` default under `$HOME` | ✅ restart + recreate |
| `/data/agent/bin` | yes | `PI_CODING_AGENT_DIR=/data/agent` | ✅ restart + recreate |
| `/workspace` | no | `PI_WEB_CWD` | ✅ restart + recreate |
| `/usr`, `/usr/local`, `/opt` | yes | — | ⚠️ restart only — lost on recreate |

## Install recipes

```bash
# Node / npm — the default and most common case
npm install -g <tool>                    # -> /data/npm/bin/<tool>

# Python (python3 + pip are in the image)
pip install --user <tool>                # -> /data/home/.local/bin/<tool>
python3 -m pip install --user <tool>     # same, if `pip` is not on PATH

# pipx / uv install into $HOME too
pip install --user pipx && pipx install <tool>
curl -LsSf https://astral.sh/uv/install.sh | sh && uv tool install <tool>

# Rust — install the toolchain itself into $HOME; it then persists as well
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
cargo install <tool>                     # -> /data/home/.cargo/bin/<tool>

# Go — the toolchain must live under $HOME too (an apt-installed go does not
# persist), and its bin dir has to be reachable from the persistent PATH
ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; esac
mkdir -p /data/home/go-toolchain
curl -fsSL "https://go.dev/dl/go1.23.4.linux-$A.tar.gz" \
  | tar -C /data/home/go-toolchain --strip-components=1 -xz
ln -sf /data/home/go-toolchain/bin/go /data/npm/bin/go        # persistent + on PATH
ln -sf /data/home/go-toolchain/bin/gofmt /data/npm/bin/gofmt
go install example.com/tool@latest       # -> /data/home/go/bin/<tool> (GOPATH)

# Bun
curl -fsSL https://bun.sh/install | bash # -> /data/home/.bun/bin/bun
bun add -g <tool>

# A standalone binary with no installer
curl -fsSL -o /data/npm/bin/<tool> <url> && chmod +x /data/npm/bin/<tool>
```

Prefer `npm install -g` when the tool is published on npm — it is the one path
that works with no extra setup.

## Verify before you trust it

```bash
command -v <tool>
```

- Path under `/data/...` → survives restarts. Good.
- Path under `/usr/...`, `/usr/local/...` or `/opt/...` → **container
  filesystem**, gone on the next recreate. Reinstall into `/data`.

To check every tool at once and flag the ones that will not survive:

```bash
for t in <tool1> <tool2>; do p=$(command -v "$t" || true); \
  case "$p" in /data/*) s=persists;; "") s=missing;; *) s="LOST on recreate";; esac; \
  printf '%-20s %-40s %s\n' "$t" "${p:-—}" "$s"; done
```

## `apt-get` is the exception — do not use it for tools you need later

`apt-get install` writes to the container filesystem, so the package survives a
plain restart but is **gone** the next time the container is recreated (image
update, `docker compose down && up`, fresh deploy) and is **not** in a `/data`
backup. It is fine for a throwaway one-off in the current session. If a system
package is genuinely needed for the deployment, it belongs in the repo's
`Dockerfile` (the `apt-get` line) and in a commit — not in a running container.

## Never install these

```bash
npm install -g pi-web-ui                     # ❌ do not
npm install -g @earendil-works/pi-coding-agent  # ❌ do not
```

pi-web-ui and the `pi` CLI are **managed by the image** at `/usr/local`, which
comes before `/data/npm` on `PATH`, and `PI_WEB_MANAGED=1` makes the in-app
updater refuse on purpose. To update either one, update the container image (pull
or rebuild it). A copy installed into `/data/npm` would be shadowed and inert —
and `docker-entrypoint.sh` deletes any it finds there at startup, so installing
them is wasted work that disappears with the next restart.

## When the tool must exist for every fresh deployment

Persistence under `/data` covers restarts and recreates **as long as the volume
is kept**. A brand-new deployment with an empty volume starts clean again, and
the volume is what a backup captures. If a tool has to be present no matter
what, add it to the `Dockerfile` (an `apt-get` package or an `npm install -g` in
the image) so it is baked in — see `AGENTS.md` in the `pi-docker` repo for the
conventions.

## Backups

`/data` is the whole persisted state, so a single archive captures the agent's
config, sessions, UI state and every tool you installed:

```bash
tar czf pi-backup-$(date +%F).tar.gz -C /data .
```
