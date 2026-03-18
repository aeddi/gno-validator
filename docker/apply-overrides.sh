#!/bin/sh
# Apply key=value entries from /config.overrides to the gnoland config.
# Usage: apply-overrides.sh [config-path]

CONFIG="${1:-/gnoland-data/config/config.toml}"
OVERRIDES="/config.overrides"

[ -f "$OVERRIDES" ] || exit 0

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
