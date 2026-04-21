#!/bin/sh
set -eu

KEYNAME="gnokms-docker-key"
KEYSTORE="/gnokms-data/keystore"

# ---- Check GNOKMS_PASSWORD is set
if [ -z "${GNOKMS_PASSWORD:-}" ]; then
  printf "Error: GNOKMS_PASSWORD is not set. Set it in validator.env or use 'make start' to be prompted.\n" >&2
  exit 1
fi

# ---- Check keystore directory exists
if [ ! -d "$KEYSTORE" ]; then
  printf "Error: keystore not found at %s.\nRun 'make gen-identity' to create it.\n" "$KEYSTORE" >&2
  exit 1
fi

# ---- Check key exists in keystore (match keyname as a whole token, not substring)
if ! gnokey list --home "$KEYSTORE" </dev/null 2>/dev/null |
  grep -qE "(^|[[:space:]])${KEYNAME}([[:space:]]|\$)"; then
  printf "Error: key '%s' not found in keystore.\nThe keystore may be invalid. Run 'make gen-identity' to generate a new one.\n" "$KEYNAME" >&2
  exit 1
fi

# ---- Allocate per-run temp dirs and wire a cleanup trap
probe_dir="$(mktemp -d /tmp/gnokms-probe.XXXXXX)"
pass_dir="$(mktemp -d /tmp/gnokms-pass.XXXXXX)"
probe_sock="$probe_dir/gnokms.sock"
pass_fifo="$pass_dir/password"

cleanup() {
  if [ -n "${probe_pid:-}" ]; then
    kill "$probe_pid" 2>/dev/null || true
  fi
  rm -rf "$probe_dir" "$pass_dir" 2>/dev/null || true
}
trap cleanup EXIT

# ---- Verify password: start gnokms briefly and confirm the socket appears
# (decryption failure exits in milliseconds; a correct password opens the socket).
probe_pid=""
printf '%s\n' "$GNOKMS_PASSWORD" | gnokms gnokey \
  -insecure-password-stdin \
  -home "$KEYSTORE" \
  -listener "unix://$probe_sock" \
  "$KEYNAME" >/dev/null 2>&1 &
probe_pid=$!

# Poll up to 5s for either the socket to appear (success) or the process to
# exit (failure — typically wrong password).
i=0
while [ "$i" -lt 50 ]; do
  if [ -S "$probe_sock" ]; then break; fi
  if ! kill -0 "$probe_pid" 2>/dev/null; then break; fi
  sleep 0.1
  i=$((i + 1))
done

if ! kill -0 "$probe_pid" 2>/dev/null; then
  printf "Error: failed to unlock key — GNOKMS_PASSWORD may be incorrect.\n" >&2
  exit 1
fi
kill "$probe_pid" 2>/dev/null || true
wait "$probe_pid" 2>/dev/null || true
probe_pid=""

if [ "${1-}" = "check" ]; then
  exit 0
fi

# ---- Clean up stale socket from a previous run (named volume persists across restarts)
rm -f /sock/gnokms.sock

# ---- Start gnokms with signal forwarding for clean container shutdown
mkfifo "$pass_fifo"
printf '%s\n' "$GNOKMS_PASSWORD" >"$pass_fifo" &

# Allow non-root containers (e.g. gnoland) to connect to the socket
umask 0

gnokms gnokey \
  -insecure-password-stdin \
  -home "$KEYSTORE" \
  -listener unix:///sock/gnokms.sock \
  -log-level debug \
  "$KEYNAME" <"$pass_fifo" &
gnokms_pid=$!

trap 'kill "$gnokms_pid" 2>/dev/null || true' HUP INT TERM

# Propagate gnokms's exit status so Docker's restart policy triggers on crashes.
# `|| status=$?` prevents set -e from aborting on a non-zero exit before we
# capture it.
status=0
wait "$gnokms_pid" || status=$?
exit "$status"
