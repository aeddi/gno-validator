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

- `GNOKMS_PASSWORD` — password to decrypt your signing key. Optional: if left empty, `make up` and `make update` will prompt for it at startup. **In production, leave this unset** — see [Password security](#password-security).
- `GNO_VERSION` — branch, tag, or commit hash to build (default: `master`)
- `GNO_REPO` — GitHub repo slug to clone gno sources from (default: `gnolang/gno`)
- `GNOLAND_RPC_PORT` — host port mapped to gnoland RPC (default: `26657`)
- `GNOLAND_P2P_PORT` — host port mapped to gnoland P2P (default: `26656`)
- `GRAFANA_PORT` — host port for the Grafana web UI (default: `3000`)
- `GNOLAND_RPC_LADDR` — interface gnoland RPC binds to (default: `0.0.0.0`). Use `127.0.0.1` when exposing RPC through a reverse proxy only.
- `GNOLAND_P2P_LADDR` — interface gnoland P2P binds to (default: `0.0.0.0`). Use `127.0.0.1` only if this node should not accept inbound peer connections.
- `GRAFANA_LADDR` — interface Grafana binds to (default: `0.0.0.0`). Use `127.0.0.1` when exposing Grafana through a reverse proxy only.
- `GNOLAND_LOG_SIZE` — number of 1 GB gnoland log files to keep (default: `30`, i.e. 30 GB total)

### 2. Generate the signing identity

```sh
make gen-identity
```

Creates the key `gnokms-docker-key` in `gnokms-data/keystore/`.

- If `GNOKMS_PASSWORD` is set in `.env`, it is used automatically (no prompt).
- Otherwise, `gnokey` will prompt you interactively.

### 3. Provide genesis.json

Copy your `genesis.json` to the repo root before starting the node:

```sh
cp /path/to/genesis.json .
```

### 4. Initialize

```sh
make init
```

Builds images and initializes `gnoland-data/config/config.toml` and `gnoland-data/secrets/`.

> **Warning:** Only run `make init` once. Re-running it on an existing node will overwrite your config and secrets.

### 5. Configure the node

```sh
cp config.overrides.example config.overrides
$EDITOR config.overrides
```

Set the required fields:

- `moniker` — human-readable node name
- `p2p.external_address` — your public P2P address, e.g. `tcp://<your-ip>:26656`
- `p2p.seeds` — comma-separated seed nodes for initial peer discovery
- `p2p.persistent_peers` — comma-separated peers to maintain persistent connections to

Each entry in `config.overrides` is applied to `gnoland-data/config/config.toml` via
`gnoland config set` on every container start. Mandatory settings (remote signer, telemetry)
are applied after and override any conflicting entries. `config.overrides` is gitignored — it
stays local to each operator.

### 6. Start

```sh
make up
```

### 7. Open Grafana

Once the stack is up, open the Grafana dashboard at [http://localhost:3000](http://localhost:3000) (or the port set in `GRAFANA_PORT`).

Anonymous access is enabled in read-only (Viewer) mode — no login required for browsing dashboards. To log in as admin, use the credentials set in `.env` (default: `admin` / `admin`).

## Operations

| Command               | Description                                                         |
| --------------------- | ------------------------------------------------------------------- |
| `make up`             | Start all services                                                  |
| `make down`           | Stop and remove containers                                          |
| `make restart`        | Quick restart (does not reload compose file)                        |
| `make logs-gnoland`   | Open interactive log TUI (level filter + search) — downloads lnav on first run |
| `make logs-gnokms`    | Follow gnokms logs                                                              |
| `make logs-telemetry` | Follow logs for all telemetry services                                          |
| `make status`         | Show container status                                               |
| `make gen-identity`   | Generate the validator signing identity                             |
| `make print-identity` | Print the validator address and public key                          |
| `make build`          | Rebuild Docker images                                               |
| `make update`         | Rebuild images and restart (binary update)                          |
| `make reset`          | Reset node state (removes db/wal, resets priv_validator_state.json) |

> After editing `config.overrides`: run `make down && make up` to apply changes.

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

**Recommended approach:** leave `GNOKMS_PASSWORD` unset and let `make up` / `make update` prompt you interactively at startup. The password is then held only in memory for the lifetime of the process.

**If you must inject the password non-interactively** (e.g. in a supervised init system), pass it as a runtime environment variable rather than persisting it to a file. Be aware that this still exposes the password in `/proc/<pid>/environ` and potentially in shell history — use a secrets manager or a systemd `EnvironmentFile` with `0600` permissions and consider whether the trade-off is acceptable for your threat model.

`GRAFANA_ADMIN_PASSWORD` and `GRAFANA_SMTP_PASSWORD` carry less sensitive material but follow the same principle: leaving them unset causes `make up` / `make update` to prompt for them at startup, keeping them out of any file on disk.

## Logging

- gnoland: up to 30 GB by default (30 × 1 GB files, rotated), configurable via `GNOLAND_LOG_SIZE`
- gnokms: up to 1 GB
- otelcol, tempo, prometheus, grafana: up to 100 MB each

## Optional: Grafana admin

By default, Grafana uses `admin` / `admin` as credentials. To set custom credentials, add to `.env`:

```sh
GRAFANA_ADMIN_USER=your-username
GRAFANA_ADMIN_PASSWORD=your-password
```

If `GRAFANA_ADMIN_USER` is set but `GRAFANA_ADMIN_PASSWORD` is not, `make up` and `make update` will prompt for the password at startup — see [Password security](#password-security).

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

The alert fires when no new block is detected for `GRAFANA_BLOCK_STALL_SECONDS`. The minimum effective value is `15` (the Prometheus scrape interval); values below that will never fire.

## Optional: Reverse Proxy

The [`reverse-proxy/`](reverse-proxy/) subfolder contains a Caddy setup that exposes the node services (RPC, Grafana, Gnockpit) over HTTPS with automatic Let's Encrypt certificates. See [`reverse-proxy/README.md`](reverse-proxy/README.md) for setup instructions.
