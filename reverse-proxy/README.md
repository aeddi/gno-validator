# reverse-proxy

Caddy reverse proxy with automatic HTTPS (Let's Encrypt) for the validator node services.

Caddy obtains and renews TLS certificates automatically — no manual cert management.
A landing page at the root domain links to all configured services.

## Prerequisites

- Docker and Docker Compose v2
- make

## DNS records

Create one unproxied A record per service pointing to your server's IP:

| Name | Type | Value |
|------|------|-------|
| `<domain>` | A | server IP |
| `<service>.<domain>` | A | server IP (one per service in `config`) |

> Records must be **unproxied** (grey cloud on Cloudflare) so Let's Encrypt can reach the server directly.

## Ports to open

| Port | Protocol | Purpose |
|------|----------|---------|
| 80   | TCP | Let's Encrypt ACME challenge + HTTP→HTTPS redirect |
| 443  | TCP/UDP | HTTPS |

> **Note:** Port `26656` (P2P) is unrelated to this proxy — Caddy does not handle P2P traffic. Open it separately on your server so your validator node is reachable by peers.

## Setup

```sh
cd reverse-proxy
cp config.example config
```

Edit `config` and set:

- `domain` — server domain, e.g. `gnoland1.mydomain.com`
- services (name=port pairs) — add, remove, or rename entries as needed

In the root `.env`, restrict RPC and Grafana to the loopback interface so they
are only reachable through the reverse proxy:

```sh
GNOLAND_RPC_LADDR=127.0.0.1
GRAFANA_LADDR=127.0.0.1
```

Then start:

```sh
make up
```

`make up` generates the Caddyfile and landing page from `config` and `templates/`,
then starts Caddy. Caddy obtains certificates on first start; renewals are fully automatic.

## Operations

| Command | Description |
|---------|-------------|
| `make up` | Start Caddy (also applies config changes) |
| `make down` | Stop and remove containers |
| `make restart` | Reload Caddyfile without downtime |
| `make logs` | Follow Caddy logs |
| `make status` | Show container status |
