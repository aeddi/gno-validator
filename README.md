# gno-validator

Docker Compose setup for a `gnoland` validator node with `gnokms` remote signing.
Both services are built from source (`gnolang/gno`).
A `sentinel` sidecar ships node metrics, logs, and OTLP traces to an external [gno-watchtower](https://github.com/aeddi/gno-watchtower) server.

## Prerequisites

- Docker and Docker Compose v2
- make

## Setup

### 1. Configure environment

```sh
cp validator.env.example validator.env
```

Edit `validator.env` and set:

- `GNOKMS_PASSWORD` — password to decrypt your signing key. Optional: if left empty, `make start` and `make update` will prompt for it at startup. **In production, leave this unset** — see [Password security](#password-security).
- `GNO_VERSION` — branch, tag, or commit hash to build (default: `master`)
- `GNO_REPO` — GitHub repo slug to clone gno sources from (default: `gnolang/gno`)
- `SENTINEL_IMAGE_TAG` — tag or digest for the sentinel image pulled from `ghcr.io/aeddi/gno-watchtower/sentinel` (default: `latest`). Pin a digest (`sha256:...`) for reproducibility; drift is reported when a tag like `latest` advances on the registry.
- `GNOLAND_RPC_PORT` — host port mapped to gnoland RPC (default: `26657`)
- `GNOLAND_P2P_PORT` — host port mapped to gnoland P2P (default: `26656`)
- `GNOLAND_RPC_LADDR` — interface gnoland RPC binds to (default: `0.0.0.0`). Use `127.0.0.1` when exposing RPC through a reverse proxy only.
- `GNOLAND_P2P_LADDR` — interface gnoland P2P binds to (default: `0.0.0.0`). Use `127.0.0.1` only if this node should not accept inbound peer connections.
- `GNOLAND_EXTRA_FLAGS` — extra flags appended to `gnoland start`, word-split on whitespace. Default: `--skip-genesis-sig-verification`. Add or remove flags as needed (e.g. `--skip-genesis-sig-verification --log-level info`).
- `GNOLAND_NTP_UPDATE` — any non-empty value enables in-container NTP sync at gnoland startup (tries `ntpd`, then `rdate`, then an HTTP `Date` header; first success wins). Default: `1`. Set empty to skip (useful when the host already runs `chronyd`/`systemd-timesyncd`).
- `GNOLAND_LOG_SIZE` — number of 1 GB gnoland log files to keep (default: `3`, i.e. 3 GB total)

### 2. Generate the signing identity

```sh
make gen-identity
```

Creates the key `gnokms-docker-key` in `gnokms-data/keystore/`.

- If `GNOKMS_PASSWORD` is set in `validator.env`, it is used automatically (no prompt).
- Otherwise, `gnokey` will prompt you interactively.

### 3. Configure the node

```sh
cp config.overrides.example config.overrides
$EDITOR config.overrides
```

Set the required fields:

- `moniker` — human-readable node name
- `p2p.external_address` — your public P2P address, e.g. `<your-ip>:26656`
- `p2p.persistent_peers` — comma-separated peers to maintain persistent connections to
- `telemetry.service_instance_id` — node identifier tagged on OTLP traces (e.g. your moniker)
- `telemetry.service_name` — service identifier tagged on OTLP traces (e.g. the chain ID)

Optional — add any other gnoland config keys (e.g. `p2p.seeds`, `consensus.timeout_commit`). The commented block at the top of `config.overrides.example` lists the system-hardcoded keys that the entrypoint always overrides.

Each entry in `config.overrides` is applied to `gnoland-data/config/config.toml` on every
node start and `make infos` run. Mandatory settings (remote signer, telemetry) are
applied after and override any conflicting entries. `config.overrides` is gitignored — it
stays local to each operator.

### 4. Provide genesis.json

Copy your `genesis.json` to the repo root before starting the node:

```sh
cp /path/to/genesis.json .
```

### 5. Configure sentinel

The sentinel sidecar ships node metrics/logs/traces to an external watchtower
server (see [gno-watchtower](https://github.com/aeddi/gno-watchtower)). Ask the
watchtower operator for the server URL and an authentication token, then:

```sh
cp sentinel.toml.example sentinel.toml
$EDITOR sentinel.toml
```

Set `server.url` and `server.token` to the values provided. Leaving the
`<placeholders>` unchanged causes the sentinel container to crash-loop with a
clear validation error at startup.

`sentinel.toml` is gitignored — stays local to each operator. The sentinel
image is pulled from `ghcr.io/aeddi/gno-watchtower/sentinel`; pin a specific
tag or digest via `SENTINEL_IMAGE_TAG` in `validator.env` (default: `latest`).

### 6. Start

```sh
make start
```

On first start, images are built, secrets and config are created, and containers come
up. On every subsequent start, gnoland's config is regenerated from scratch and
`config.overrides` is re-applied — so edits to `config.overrides` take effect after a
`make restart`.

## Operations

### Lifecycle

| Command                 | What it does                                                                                                                                                                                    | Cost                                            |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| `make start`            | First run: builds images + creates containers. Stopped containers: resumes them (preserves container logs). Already running: no-op, prints a drift report if any input changed since last boot. | Free after first run.                           |
| `make stop`             | Stops services but keeps containers (no recreate). Idempotent.                                                                                                                                  | Free.                                           |
| `make restart`          | `stop` + `start`. Re-applies `config.overrides` on the way up.                                                                                                                                  | Free.                                           |
| `make update [force=1]` | Rebuilds images if build inputs changed, pulls sentinel on digest drift, recreates containers if `validator.env` / `docker-compose.yml` changed. `force=1` does everything unconditionally.     | Rebuild minutes; recreate wipes container logs. |
| `make reset [yes=1]`    | Wipes chain state (`db`, `wal`, `priv_validator_state.json`). Prompts to stop and restart around the wipe; `yes=1` skips all prompts. Preserves keystore, validator keys, and node_id.          | Destructive on chain DB.                        |

### Build (rarely needed manually)

| Command                | What it does                                                                                                                                                                                                          |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make build [force=1]` | Builds images when `.build-state` doesn't match the current inputs (gno commit, `Dockerfile`, entrypoints) or the tagged images are missing. `force=1` rebuilds anyway. `start` and `update` call this automatically. |

### Inspection

| Command                     | What it does                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `make status [watch=<sec>]` | Node status table (height, peers, validator VP, sync). `watch=N` refreshes every N seconds (requires jq — auto-installed under `.tools/bin/` if absent; falls back to raw JSON if install fails).                                                                                                                                                                                                                        |
| `make infos`                | Validator identity, network config, build metadata, binary checksums.                                                                                                                                                                                                                                                                                                                                                    |
| `make logs [since=<d>]`     | Merged TUI of gnoland + gnokms + sentinel logs via [gonzo](https://github.com/control-theory/gonzo). Per-service defaults: gnoland=1h, gnokms/sentinel=24h. `since=X` overrides all three. Each line is tagged `service.name` so the built-in Service column filters by origin. Auto-installed under `.tools/bin/` on first use; config lives at `.tools/gonzo.yml` (tracked). Press `?` inside the TUI for keybindings. |

### Cleanup

| Command                           | What it does                                                                                                                                                                                                                                                        |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make clean-imgs [all=1] [yes=1]` | Default: remove stale `gno-validator-*` tags (anything not matching the current `.build-state`). `all=1` removes all gno-validator images and the sentinel image too. `yes=1` skips the confirm prompt. Refuses if any container still references a targeted image. |

### Setup

| Command             | What it does                                                    |
| ------------------- | --------------------------------------------------------------- |
| `make gen-identity` | Generate the validator signing identity in the gnokms keystore. |
| `make help`         | Show the target list.                                           |

### Change → command cheat sheet

| You edited…                            | Minimum command |
| -------------------------------------- | --------------- |
| `config.overrides`                     | `make restart`  |
| `validator.env`, `docker-compose.yml`  | `make update`   |
| `Dockerfile`, `docker/*-entrypoint.sh` | `make update`   |
| Upstream `GNO_VERSION` branch moved    | `make update`   |

> `make update` prompts before recreating — pass `force=1` to skip the prompt.

### How drift detection works

`make build` writes `.build-state` (gitignored) recording the commit, version, repo, per-image content hashes, and the sentinel image digest resolved from ghcr. `make start` and `make update` read it back and report drift precisely (e.g., `gno commit advanced on chain/test12: 8513a68f → 9a2b4c1e`, or `sentinel image advanced on latest: 8513a68f → 9a2b4c1e`). The gnoland commit check hits `git ls-remote`, and the sentinel check hits `docker manifest inspect`; both gracefully skip on network failure.

Downloaded tools (gonzo, jq) live under `.tools/bin/` (gitignored, auto-fetched on first use). Gonzo's config lives at `.tools/gonzo.yml` (tracked).

## Architecture

- **gnoland** exposes RPC (`GNOLAND_RPC_PORT`, default `26657`) and P2P (`GNOLAND_P2P_PORT`, default `26656`) to the host. When `GNOLAND_NTP_UPDATE` is set (default), the container syncs its clock before launching gnoland, trying `ntpd`, then `rdate`, then an HTTPS `Date` header until one succeeds. The container has `CAP_SYS_TIME`, so on a Linux host this also updates the host's clock — disable `GNOLAND_NTP_UPDATE` if another NTP daemon already manages the host.
- **gnokms** communicates with gnoland over a Unix socket — no network port is exposed.
- **sentinel** collects gnoland RPC status, container logs, OTLP traces, and system resources, then forwards them to a central watchtower server. Image is pulled from `ghcr.io/aeddi/gno-watchtower/sentinel` (tag set via `SENTINEL_IMAGE_TAG`).
- `gnoland-data/`, `gnokms-data/`, and `genesis.json` are gitignored — back them up.

## Password security

The keystore is encrypted with `GNOKMS_PASSWORD`. In production, **do not store this password on disk** — including `validator.env`.

If the password is written to `validator.env`, an attacker who dumps the disk (via snapshot, backup exfiltration, or physical access) gets both the encrypted keystore and the key to decrypt it. Keeping the password only in RAM means disk access alone is not enough.

**Recommended approach:** leave `GNOKMS_PASSWORD` unset and let `make start` / `make update` prompt you interactively at startup. The password is then held only in memory for the lifetime of the process.

**If you must inject the password non-interactively** (e.g. in a supervised init system), pass it as a runtime environment variable rather than persisting it to a file. Be aware that this still exposes the password in `/proc/<pid>/environ` and potentially in shell history — use a secrets manager or a systemd `EnvironmentFile` with `0600` permissions and consider whether the trade-off is acceptable for your threat model.

## Logging

- gnoland: up to 3 GB by default (3 × 1 GB files, rotated), configurable via `GNOLAND_LOG_SIZE`
- gnokms: up to 1 GB
- sentinel: up to 100 MB

## Optional: Reverse Proxy

The [`reverse-proxy/`](reverse-proxy/) subfolder contains a Caddy setup that exposes the node services (RPC, Gnockpit) over HTTPS with automatic Let's Encrypt certificates. See [`reverse-proxy/README.md`](reverse-proxy/README.md) for setup instructions.
