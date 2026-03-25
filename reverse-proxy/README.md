# reverse-proxy

Caddy reverse proxy with automatic HTTPS (Let's Encrypt) for the validator node services.

Caddy obtains and renews TLS certificates automatically — no manual cert management.
A landing page at the root domain links to all three services.

## Prerequisites

- Docker and Docker Compose v2
- make
- `envsubst` (part of `gettext`, available on most Linux distros)

## DNS records

Create one unproxied A record per service pointing to your server's IP:

| Name | Type | Value |
|------|------|-------|
| `<chain-id>.<domain>` | A | server IP |
| `rpc.<chain-id>.<domain>` | A | server IP |
| `grafana.<chain-id>.<domain>` | A | server IP |
| `gnockpit.<chain-id>.<domain>` | A | server IP |

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
cp .env.example .env
```

Edit `.env` and set:

- `DOMAIN` — server domain, e.g. `gnoland1.mydomain.com`

Then start:

```sh
make up
```

Caddy will obtain certificates on first start. Subsequent renewals are fully automatic.

## Operations

| Command | Description |
|---------|-------------|
| `make up` | Start Caddy (also applies config changes) |
| `make down` | Stop and remove containers |
| `make restart` | Reload Caddyfile without downtime |
| `make logs` | Follow Caddy logs |
| `make status` | Show container status |
