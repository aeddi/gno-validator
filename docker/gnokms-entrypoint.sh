#!/bin/sh

KEYNAME="gnokms-docker-key"
KEYSTORE="/gnokms-data/keystore"

# ---- Check GNOKMS_PASSWORD is set
if [ -z "$GNOKMS_PASSWORD" ]; then
  printf "Error: GNOKMS_PASSWORD is not set. Set it in .env or use 'make up' to be prompted.\n" >&2
  exit 1
fi

# ---- Check keystore directory exists
if [ ! -d "$KEYSTORE" ]; then
  printf "Error: keystore not found at %s.\nRun 'make gen-identity' to create it.\n" "$KEYSTORE" >&2
  exit 1
fi

# ---- Check key exists in keystore
if ! gnokey list --home "$KEYSTORE" </dev/null 2>/dev/null | grep -q "$KEYNAME"; then
  printf "Error: key '%s' not found in keystore.\nThe keystore may be invalid. Run 'make gen-identity' to generate a new one.\n" "$KEYNAME" >&2
  exit 1
fi

# ---- Verify password: start gnokms briefly and confirm it does not exit immediately
# (a decryption failure exits in milliseconds; a correct password keeps the server running)
probe_sock="/tmp/gnokms-probe-$$.sock"
printf '%s\n' "$GNOKMS_PASSWORD" | gnokms gnokey \
  -insecure-password-stdin \
  -home "$KEYSTORE" \
  -listener "unix://$probe_sock" \
  "$KEYNAME" >/dev/null 2>&1 &
probe_pid=$!
sleep 2
if ! kill -0 "$probe_pid" 2>/dev/null; then
  rm -f "$probe_sock"
  printf "Error: failed to unlock key — GNOKMS_PASSWORD may be incorrect.\n" >&2
  exit 1
fi
kill "$probe_pid" 2>/dev/null || true
wait "$probe_pid" 2>/dev/null || true
rm -f "$probe_sock"

# ---- Clean up stale socket from a previous run (named volume persists across restarts)
rm -f /sock/gnokms.sock

# ---- Start gnokms with signal forwarding for clean container shutdown
mkfifo /tmp/gnokms-pass-$$
printf '%s\n' "$GNOKMS_PASSWORD" > /tmp/gnokms-pass-$$ &
gnokms gnokey \
  -insecure-password-stdin \
  -home "$KEYSTORE" \
  -listener unix:///sock/gnokms.sock \
  "$KEYNAME" < /tmp/gnokms-pass-$$ &
gnokms_pid=$!
rm -f /tmp/gnokms-pass-$$

trap 'kill "$gnokms_pid" 2>/dev/null' TERM INT
wait "$gnokms_pid"
