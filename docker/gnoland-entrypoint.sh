#!/bin/sh
set -eu

# ---- Node initialization
# Runs when 'gnoland start' is invoked (normal path) or when GNOLAND_INIT_ONLY=1
# is set (host-side `make infos` uses this to materialize config without
# starting the node).
do_init() {
  # Initialize secrets only when missing — never overwrite an existing key.
  if [ ! -f /gnoland-data/secrets/priv_validator_key.json ]; then
    gnoland secrets init >/dev/null
  fi
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

# ---- System time sync
# Try multiple methods in order, stopping at the first success. Each attempt
# prints one status line so operators can see what worked.
#   1. busybox ntpd  — UDP/123, most common.
#   2. busybox rdate — TCP/37 (RFC 868), often firewalled; try anyway.
#   3. HTTP Date     — pull the Date header from an HTTPS endpoint and feed
#                       it to busybox `date -D`; works wherever HTTPS is open.
# Each method is bounded with `timeout` so a hung server doesn't stall startup.
_sync_time_ntpd() {
  timeout 10 ntpd -nq -p pool.ntp.org >/dev/null 2>&1
}

_sync_time_rdate() {
  timeout 10 rdate time.nist.gov >/dev/null 2>&1
}

_sync_time_http() {
  http_date=$(wget -qS --spider --timeout=5 https://www.google.com 2>&1 |
    awk '/^[[:space:]]*Date:/{sub(/^[[:space:]]*Date: */, ""); print; exit}')
  [ -n "$http_date" ] || return 1
  date -u -D '%a, %d %b %Y %H:%M:%S GMT' -s "$http_date" >/dev/null 2>&1
}

sync_time() {
  printf 'Syncing system time:\n'
  _synced=0
  for name in ntpd rdate http; do
    if [ "$_synced" = 1 ]; then
      printf '  %-8s skipped\n' "${name}:"
      continue
    fi
    if "_sync_time_$name"; then
      printf '  %-8s succeeded\n' "${name}:"
      _synced=1
    else
      printf '  %-8s failed\n' "${name}:"
    fi
  done
  [ "$_synced" = 1 ] ||
    printf 'Warning: all time-sync methods failed; continuing with current clock\n' >&2
}

# ---- Init-only mode (no gnoland start)
if [ "${GNOLAND_INIT_ONLY:-}" = "1" ]; then
  do_init
  exit 0
fi

# ---- Full start path
if [ "${1-}" = "gnoland" ] && [ "${2-}" = "start" ]; then
  do_init

  if [ -n "${GNOLAND_NTP_UPDATE:-}" ]; then
    sync_time
  fi

  # ---- Append operator-provided extra flags (word-split on whitespace).
  # Operator sets GNOLAND_EXTRA_FLAGS in validator.env; the default in
  # validator.env.example includes --skip-genesis-sig-verification.
  # shellcheck disable=SC2086 # intentional word-splitting
  if [ -n "${GNOLAND_EXTRA_FLAGS:-}" ]; then
    set -- "$@" $GNOLAND_EXTRA_FLAGS
  fi
fi

exec "$@"
