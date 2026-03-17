#!/bin/sh

CONFIG="/gnoland-data/config/config.toml"

# ---- Config setup only applies when starting the node
if [ "$2" = "start" ]; then
  # ---- Check config.toml exists
  if [ ! -f "$CONFIG" ]; then
    printf "Error: config not found at %s.\nRun 'make init' first.\n" "$CONFIG" >&2
    exit 1
  fi

  # ---- Apply user config overrides
  OVERRIDES="/config.overrides"
  if [ -f "$OVERRIDES" ]; then
    while IFS= read -r line; do
      case "$line" in
      '' | '#'*) continue ;;
      esac
      key="${line%%=*}"
      value="${line#*=}"
      key="${key#"${key%%[! ]*}"}"
      key="${key%"${key##*[! ]}"}"
      value="${value#"${value%%[! ]*}"}"
      value="${value%"${value##*[! ]}"}"
      value="${value#\"}"
      value="${value%\"}"
      gnoland config set "$key" "$value" -config-path "$CONFIG" >/dev/null
    done <"$OVERRIDES"
  fi

  # ---- Apply required config overrides
  gnoland config set p2p.laddr tcp://127.0.0.1:26656 \
    -config-path "$CONFIG" >/dev/null
  gnoland config set rpc.laddr tcp://127.0.0.1:26657 \
    -config-path "$CONFIG" >/dev/null
  gnoland config set consensus.priv_validator.remote_signer.server_address unix:///sock/gnokms.sock \
    -config-path "$CONFIG" >/dev/null
  gnoland config set telemetry.metrics_enabled true \
    -config-path "$CONFIG" >/dev/null
  gnoland config set telemetry.traces_enabled true \
    -config-path "$CONFIG" >/dev/null
  gnoland config set telemetry.exporter_endpoint http://otelcol:4318 \
    -config-path "$CONFIG" >/dev/null
  gnoland config set telemetry.service_instance_id validator \
    -config-path "$CONFIG" >/dev/null

  if [ -n "$GNOLAND_EARLY_START" ]; then
    set -- "$@" -x-early-start
  fi
fi

exec "$@"
