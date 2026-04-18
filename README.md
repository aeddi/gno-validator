# gno-validator

Docker Compose setup for a `gnoland` validator node with `gnokms` remote signing.
Both services are built from source (`gnolang/gno`).
Additionally, OpenTelemetry is set up to collect traces from `gnoland` and visualize them in Grafana, with Tempo as the backend.

## Prerequisites

- Docker and Docker Compose v2
- make

## Setup

### 1. Configure environment

```sh
cp .env.example .env
```

Edit `.env` and set:

- `GNOKMS_PASSWORD` — password to decrypt your signing key. Optional: if left empty, `make start` and `make update` will prompt for it at startup. **In production, leave this unset** — see [Password security](#password-security).
- `GNO_VERSION` — branch, tag, or commit hash to build (default: `master`)
- `GNO_REPO` — GitHub repo slug to clone gno sources from (default: `gnolang/gno`)
- `GNOLAND_RPC_PORT` — host port mapped to gnoland RPC (default: `26657`)
- `GNOLAND_P2P_PORT` — host port mapped to gnoland P2P (default: `26656`)
- `GRAFANA_PORT` — host port for the Grafana web UI (default: `3000`)
- `GNOLAND_RPC_LADDR` — interface gnoland RPC binds to (default: `0.0.0.0`). Use `127.0.0.1` when exposing RPC through a reverse proxy only.
- `GNOLAND_P2P_LADDR` — interface gnoland P2P binds to (default: `0.0.0.0`). Use `127.0.0.1` only if this node should not accept inbound peer connections.
- `GRAFANA_LADDR` — interface Grafana binds to (default: `0.0.0.0`). Use `127.0.0.1` when exposing Grafana through a reverse proxy only.
- `GNOLAND_LOG_SIZE` — number of 1 GB gnoland log files to keep (default: `3`, i.e. 3 GB total)

### 2. Generate the signing identity

```sh
make gen-identity
```

Creates the key `gnokms-docker-key` in `gnokms-data/keystore/`.

- If `GNOKMS_PASSWORD` is set in `.env`, it is used automatically (no prompt).
- Otherwise, `gnokey` will prompt you interactively.

### 3. Configure the node

```sh
cp config.overrides.example config.overrides
$EDITOR config.overrides
```

Set the required fields:

- `moniker` — human-readable node name
- `p2p.external_address` — your public P2P address, e.g. `tcp://<your-ip>:26656`
- `p2p.seeds` — comma-separated seed nodes for initial peer discovery
- `p2p.persistent_peers` — comma-separated peers to maintain persistent connections to
- `telemetry.service_instance_id` — node identifier shown in Grafana (e.g. your moniker)
- `telemetry.service_name` — service identifier shown in Grafana (e.g. the chain ID)

Each entry in `config.overrides` is applied to `gnoland-data/config/config.toml` on every
node start and `make infos` run. Mandatory settings (remote signer, telemetry) are
applied after and override any conflicting entries. `config.overrides` is gitignored — it
stays local to each operator.

### 4. Provide genesis.json

Copy your `genesis.json` to the repo root before starting the node:

```sh
cp /path/to/genesis.json .
```

### 5. Start

```sh
make start
```

On first start, images are built, secrets and config are created, and containers come
up. On every subsequent start, gnoland's config is regenerated from scratch and
`config.overrides` is re-applied — so edits to `config.overrides` take effect after a
`make restart`.

### 6. Open Grafana

Once the stack is up, open the Grafana dashboard at [http://localhost:3000](http://localhost:3000) (or the port set in `GRAFANA_PORT`).

Anonymous access is enabled in read-only (Viewer) mode — no login required for browsing dashboards. To log in as admin, use the credentials set in `.env` (default: `admin` / `admin`).

## Operations

### Lifecycle

| Command                 | What it does                                                                  | Cost                                              |
| ----------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------- |
| `make start`            | First run: builds images + creates containers. Otherwise resumes stopped containers. | Free after first run.                         |
| `make stop`             | Stops services but keeps containers (no recreate).                            | Free.                                             |
| `make restart`          | `stop` + `start`. Re-applies `config.overrides` on the way up.                | Free. No password prompt.                         |
| `make update [force=1]` | Rebuilds images if build inputs changed, recreates containers if `.env` / `docker-compose.yml` changed. `force=1` does both unconditionally. | Rebuild minutes; recreate wipes container logs. |
| `make reset`            | Wipes chain state (`db`, `wal`, `priv_validator_state.json`). Prompts to stop and restart around the wipe. Preserves keystore, validator keys, node_id, and Grafana data. | Destructive on chain DB. |

### Build (rarely needed manually)

| Command                 | What it does                                                                  |
| ----------------------- | ----------------------------------------------------------------------------- |
| `make build [force=1]`  | Builds images whose labels don't match the current commit / Dockerfile / entrypoint. `force=1` rebuilds anyway. `start` and `update` call this automatically. |

### Inspection

| Command                 | What it does                                                                  |
| ----------------------- | ----------------------------------------------------------------------------- |
| `make status`           | Container status (`docker compose ps`).                                       |
| `make infos`            | Validator identity, network config, build metadata, binary checksums.         |
| `make logs-gnoland`     | Interactive log TUI (lnav). `SINCE=<duration>` controls history (default 1h). |
| `make logs-gnokms`      | Follow gnokms logs.                                                           |
| `make logs-telemetry`   | Follow otelcol / tempo / prometheus / grafana logs.                           |

### Setup

| Command                 | What it does                                                                  |
| ----------------------- | ----------------------------------------------------------------------------- |
| `make gen-identity`     | Generate the validator signing identity in the gnokms keystore.               |
| `make help`             | Show the target list.                                                         |

### Change → command cheat sheet

| You edited…                                    | Minimum command |
| ---------------------------------------------- | --------------- |
| `config.overrides`                             | `make restart`  |
| `.env`, `docker-compose.yml`                   | `make update`   |
| `Dockerfile`, `docker/*-entrypoint.sh`         | `make update`   |
| Upstream `GNO_VERSION` branch moved            | `make update`   |

> `make update` prompts before recreating — pass `force=1` to skip the prompt.

## Architecture

- **gnoland** exposes RPC (`GNOLAND_RPC_PORT`, default `26657`) and P2P (`GNOLAND_P2P_PORT`, default `26656`) to the host. On startup, the container syncs the system clock via NTP before launching gnoland, ensuring accurate timing when waiting for `genesis_time` to elapse.
- **gnokms** communicates with gnoland over a Unix socket — no network port is exposed.
- **otelcol** receives traces from gnoland and forwards them to tempo.
- **tempo** stores distributed traces.
- **prometheus** scrapes metrics from otelcol.
- **grafana** exposes the observability dashboard (`GRAFANA_PORT`, default `3000`) — backed by prometheus and tempo.
- `gnoland-data/`, `gnokms-data/`, and `genesis.json` are gitignored — back them up.

## Password security

The keystore is encrypted with `GNOKMS_PASSWORD`. In production, **do not store this password on disk** — including `.env`.

If the password is written to `.env`, an attacker who dumps the disk (via snapshot, backup exfiltration, or physical access) gets both the encrypted keystore and the key to decrypt it. Keeping the password only in RAM means disk access alone is not enough.

**Recommended approach:** leave `GNOKMS_PASSWORD` unset and let `make start` / `make update` prompt you interactively at startup. The password is then held only in memory for the lifetime of the process.

**If you must inject the password non-interactively** (e.g. in a supervised init system), pass it as a runtime environment variable rather than persisting it to a file. Be aware that this still exposes the password in `/proc/<pid>/environ` and potentially in shell history — use a secrets manager or a systemd `EnvironmentFile` with `0600` permissions and consider whether the trade-off is acceptable for your threat model.

`GRAFANA_ADMIN_PASSWORD` and `GRAFANA_SMTP_PASSWORD` carry less sensitive material but follow the same principle: leaving them unset causes `make start` / `make update` to prompt for them at startup, keeping them out of any file on disk.

## Logging

- gnoland: up to 3 GB by default (3 × 1 GB files, rotated), configurable via `GNOLAND_LOG_SIZE`
- gnokms: up to 1 GB
- otelcol, tempo, prometheus, grafana: up to 100 MB each

## Optional: Grafana admin

By default, Grafana uses `admin` / `admin` as credentials. To set custom credentials, add to `.env`:

```sh
GRAFANA_ADMIN_USER=your-username
GRAFANA_ADMIN_PASSWORD=your-password
```

If `GRAFANA_ADMIN_USER` is set but `GRAFANA_ADMIN_PASSWORD` is not, `make start` and `make update` will prompt for the password at startup — see [Password security](#password-security).

Admin credentials are required to configure alerting contact points and manage users.

## Optional: Grafana alerting

Grafana can send an email alert if no new block has been produced for a configurable duration. This requires SMTP and a Grafana admin user to be configured.

Add to `.env`:

```sh
GRAFANA_ADMIN_USER=your-username        # required for alerting to be provisioned
GRAFANA_SMTP_ENABLED=true
GRAFANA_SMTP_HOST=smtp.example.com:587
GRAFANA_SMTP_USER=your-smtp-user
GRAFANA_SMTP_FROM_ADDRESS=alerts@example.com
GRAFANA_SMTP_FROM_NAME=Grafana
GRAFANA_SMTP_PASSWORD=your-smtp-password  # or leave unset to be prompted at startup
GRAFANA_ALERT_EMAIL_ADDRESSES=you@example.com,other@example.com
GRAFANA_BLOCK_STALL_SECONDS=300           # seconds without a new block before alerting (default: 300)
```

The alert fires when no new block is detected for `GRAFANA_BLOCK_STALL_SECONDS`. The minimum effective value is `90`: the alert uses `increase()` over this window, which requires at least 2 data points from the gnoland OTLP push interval (~60s) — values below ~90s risk returning no data intermittently and missing alerts.

## Optional: Reverse Proxy

The [`reverse-proxy/`](reverse-proxy/) subfolder contains a Caddy setup that exposes the node services (RPC, Grafana, Gnockpit) over HTTPS with automatic Let's Encrypt certificates. See [`reverse-proxy/README.md`](reverse-proxy/README.md) for setup instructions.
