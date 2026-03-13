# gno-validator

Docker Compose setup for a `gnoland` validator node with `gnokms` remote signing on the `gnoland1` network.
Both services are built from source (`gnolang/gno@master`).

## Prerequisites

- Docker and Docker Compose v2
- make
- `gnokey` — for populating the gnokms keystore (install from [gnolang/gno](https://github.com/gnolang/gno))

## Setup

### 1. Configure environment

```sh
cp .env.example .env
```

Edit `.env` and set:
- `GNOKMS_PASSWORD` — password to decrypt your signing key
- `GNOKMS_KEY_NAME` — name of the key in `gnokms-data/keystore/`

### 2. Populate the gnokms keystore

Before first run, add your validator signing key to `gnokms-data/keystore/` using `gnokey`:

```sh
gnokey add --recover <GNOKMS_KEY_NAME> --home gnokms-data/keystore
```

The key name must match `GNOKMS_KEY_NAME` in `.env`.

### 3. Initialize

```sh
make init
```

Builds images, generates `genesis.json` (~200 MB, takes several minutes on first run),
and initializes `gnoland-data/config/config.toml` and `gnoland-data/secrets/`.

> **Warning:** Only run `make init` once. Re-running it on an existing node will overwrite your config and secrets.

### 4. Edit the node config

```sh
$EDITOR gnoland-data/config/config.toml
```

Required fields to update:
- `moniker` — human-readable node name
- `p2p.external_address` — your public P2P address, e.g. `tcp://<your-ip>:26656`

### 5. Start

```sh
make up
```

## Operations

| Command | Description |
|---|---|
| `make up` | Start all services |
| `make down` | Stop and remove containers |
| `make restart` | Quick restart (does not reload compose file) |
| `make logs` | Follow all service logs |
| `make logs-gnoland` | Follow gnoland logs |
| `make logs-gnokms` | Follow gnokms logs |
| `make status` | Show container status |
| `make build` | Rebuild Docker images |
| `make update` | Rebuild images and restart (binary update) |
| `make genesis` | Regenerate `genesis.json` |

> After editing `gnoland-data/config/config.toml`: run `make down && make up` to apply changes.

## Architecture

- **gnoland** exposes ports `26657` (RPC) and `26656` (P2P) to the host.
- **gnokms** communicates with gnoland over a Unix socket — no network port is exposed.
- `gnoland-data/` and `gnokms-data/` are bind-mounted from the host and gitignored — back them up.
- `genesis.json` is gitignored (~200 MB) — regenerate with `make genesis`.

## Logging

- gnoland: up to 30 GB (30 × 1 GB files, rotated)
- gnokms: up to 1 GB
