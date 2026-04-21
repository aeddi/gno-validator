#!/bin/sh
set -eu

# Only run node initialization when invoked with the real 'gnoland start'
# command. Other invocations (e.g. 'gnoland genesis ...', 'sh', etc.) exec
# directly without touching config.
if [ "${1-}" = "gnoland" ] && [ "${2-}" = "start" ]; then
  # ---- Create secrets if missing, always reset config to defaults
  # `secrets init` errors if files already exist — that's expected, continue.
  gnoland secrets init >/dev/null 2>&1 || true
  gnoland config init -force >/dev/null

  # ---- Apply operator config overrides (moniker, peers, external address, etc.)
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
      gnoland config set "$key" "$value" >/dev/null
    done <"$OVERRIDES"
  fi

  # ---- Apply hardcoded config overrides required by the Docker setup
  gnoland config set p2p.laddr tcp://0.0.0.0:26656 >/dev/null
  gnoland config set rpc.laddr tcp://0.0.0.0:26657 >/dev/null
  gnoland config set consensus.priv_validator.remote_signer.server_address unix:///sock/gnokms.sock >/dev/null
  gnoland config set telemetry.metrics_enabled true >/dev/null
  gnoland config set telemetry.traces_enabled true >/dev/null
  gnoland config set telemetry.exporter_endpoint http://sentinel:4318 >/dev/null

  # ---- Sync clock and handle early start flag
  if [ -n "${GNOLAND_NTP_UPDATE:-}" ]; then
    ntpd -nq -p pool.ntp.org || printf "Warning: NTP sync failed, continuing with current clock\n" >&2
  fi
  if [ -n "${GNOLAND_EARLY_START:-}" ]; then
    set -- "$@" -x-early-start
  fi
fi

exec "$@"
