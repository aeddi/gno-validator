#!/bin/sh
set -eu

# ---- Node initialization
# Runs when 'gnoland start' is invoked (normal path) or when GNOLAND_INIT_ONLY=1
# is set (host-side `make infos` uses this to materialize config without
# starting the node).
do_init() {
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

  # ---- Record what was just applied so the host can detect config.overrides drift.
  # Compute the hash to a variable first, validate it's non-empty, then write
  # atomically. A naive `sha256sum | awk >tmp` pipeline masks sha256sum failure
  # (awk still succeeds with empty output), which would record an empty hash
  # and produce permanent false-positive drift until cleared.
  tmp="/gnoland-data/.applied-overrides.sha256.tmp"
  out="/gnoland-data/.applied-overrides.sha256"
  if [ -f "$OVERRIDES" ]; then
    hash="$(sha256sum "$OVERRIDES" 2>/dev/null | awk '{print $1}')"
  else
    # No overrides file → record the sha of the empty file so drift comparison
    # has a definite baseline ("nothing was applied from overrides").
    hash="$(printf '' | sha256sum 2>/dev/null | awk '{print $1}')"
  fi
  if [ -n "$hash" ]; then
    printf '%s\n' "$hash" >"$tmp" && mv -f "$tmp" "$out" || rm -f "$tmp"
  fi
}

# ---- Init-only mode (no gnoland start)
if [ "${GNOLAND_INIT_ONLY:-}" = "1" ]; then
  do_init
  exit 0
fi

# ---- Full start path
if [ "${1-}" = "gnoland" ] && [ "${2-}" = "start" ]; then
  do_init

  # ---- Sync clock and handle early start flag
  if [ -n "${GNOLAND_NTP_UPDATE:-}" ]; then
    ntpd -nq -p pool.ntp.org || printf "Warning: NTP sync failed, continuing with current clock\n" >&2
  fi
  if [ -n "${GNOLAND_EARLY_START:-}" ]; then
    set -- "$@" -x-early-start
  fi
fi

exec "$@"
