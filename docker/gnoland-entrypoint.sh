#!/bin/sh

CONFIG="/gnoland-data/config/config.toml"

# ---- Check config.toml exists
if [ ! -f "$CONFIG" ]; then
  printf "Error: config not found at %s.\nRun 'make init' first.\n" "$CONFIG" >&2
  exit 1
fi

# ---- Apply required config overrides
gnoland config set consensus.priv_validator.remote_signer.server_address unix:///sock/gnokms.sock \
  -config-path "$CONFIG"
gnoland config set telemetry.metrics_enabled true \
  -config-path "$CONFIG"
gnoland config set telemetry.exporter_endpoint otelcol:4317 \
  -config-path "$CONFIG"

exec "$@"

