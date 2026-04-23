#!/usr/bin/env bash
# .Makefile.sh — shell backend for the gno-validator Makefile.
#
# Holds every operational command (build, start, stop, gen-identity, ...) so the
# Makefile stays a thin dispatcher. Normally invoked as `make <target>`; can
# also be run directly with `bash .Makefile.sh <command>` from the repo root.
#
# Usage: .Makefile.sh <command>
# Commands: gen-identity, infos, build, start, stop, restart, logs-gnoland,
#           logs-gnokms, logs-sentinel, status, reset, update, clean-imgs

set -Eeuo pipefail

# The ERR trap prints a raw diagnostic (line + failing command) for unexpected
# failures. When our own error handlers (err_*) emit a clean message, they set
# HANDLED_ERROR=1 so the trap stays quiet — otherwise the operator sees the
# friendly error followed by a confusing internal trace.
HANDLED_ERROR=0
trap '(( HANDLED_ERROR )) || echo "Error: command failed (line ${LINENO}): ${BASH_COMMAND}" >&2' ERR

# ---- Globals

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

# Cached once so platform switches (stat, date, ...) don't re-fork `uname`.
UNAME_S="$(uname -s)"
readonly UNAME_S

ENV_FILE="validator.env"
STATE_FILE=".build-state"
OVERRIDES_FILE="config.overrides"
GENESIS_FILE="genesis.json"
COMPOSE_FILE="docker-compose.yml"
APPLIED_OVERRIDES_FILE="gnoland-data/.applied-overrides.sha256"

GNOKMS_IMAGE="gno-validator-gnokms"
GNOLAND_IMAGE="gno-validator-gnoland"
GNOKMS_DATA="gnokms-data"
GNOLAND_DATA="gnoland-data"
GNOKMS_KEYNAME="gnokms-docker-key"

GNOLAND_CONTAINER="gno-validator-gnoland-1"
GNOKMS_CONTAINER="gno-validator-gnokms-1"
SENTINEL_CONTAINER="gno-validator-sentinel-1"

LNAV_VERSION="0.13.2"
JQ_VERSION="1.7.1"
TOOLS_BIN_DIR=".tools/bin"
LNAV_BIN="${TOOLS_BIN_DIR}/lnav"
JQ_BIN="${TOOLS_BIN_DIR}/jq"

# Host UID/GID are consumed by docker-compose.yml for gnoland's user mapping
# (keeps files under gnoland-data/ owned by the operator, not root).
export HOST_UID="${HOST_UID:-$(id -u)}"
export HOST_GID="${HOST_GID:-$(id -g)}"

# ---- Error printers
# Canonical, user-facing error messages. Each sets HANDLED_ERROR=1 so the ERR
# trap stays quiet (the operator should see the friendly message, not the
# internal trace), and returns 1 so callers can chain with `||` and propagate.

err_docker() {
  HANDLED_ERROR=1
  echo "Error: Docker is required but unavailable. Start Docker (or install it) and retry." >&2
  return 1
}

err_genesis_missing() {
  HANDLED_ERROR=1
  echo "Error: genesis.json not found. Place the chain genesis at ./${GENESIS_FILE} before continuing." >&2
  return 1
}

err_keystore_missing() {
  HANDLED_ERROR=1
  echo "Error: validator keystore is empty. Run 'make gen-identity' to create the signing key." >&2
  return 1
}

err_gnokms_running() {
  HANDLED_ERROR=1
  echo "Error: gnokms is running and holds the keystore lock. Run 'make stop' first." >&2
  return 1
}

err_password_mismatch() {
  HANDLED_ERROR=1
  echo "Error: GNOKMS_PASSWORD is not correct for the keystore." >&2
  echo "       Re-run with the correct password, or update validator.env." >&2
  return 1
}

err_containers_in_use() {
  HANDLED_ERROR=1
  echo "Error: containers exist using these images: $*" >&2
  echo "       Run 'make stop' then 'docker compose down' first (or 'make update force=1' to recreate), then retry." >&2
  return 1
}

err_non_tty() {
  local flag="$1"
  HANDLED_ERROR=1
  echo "Error: non-interactive session; pass ${flag} to proceed." >&2
  return 1
}

err_build_failed() {
  HANDLED_ERROR=1
  echo "Error: image build failed. See output above." >&2
  echo "       Likely causes: network offline, GNO_VERSION doesn't exist on GNO_REPO, or a Dockerfile / entrypoint error." >&2
  return 1
}

err_no_containers_for_restart() {
  HANDLED_ERROR=1
  echo "Error: no containers to restart. Run 'make start' first." >&2
  return 1
}

# ---- Compose wrappers
# _compose (with --env-file) is the default; targets that don't need env
# interpolation (stop, logs) use _compose_noenv so a missing validator.env
# doesn't block log viewing or container stops.

_compose() {
  docker compose --env-file "$ENV_FILE" "$@"
}

_compose_noenv() {
  docker compose "$@"
}

# ---- validator.env helpers

# Print the raw value of KEY from validator.env (preserves whitespace, empty if unset).
# Uses awk with literal string comparison so keys with regex metacharacters
# (.  * [ etc.) are matched safely.
env_get_raw() {
  [[ -f "$ENV_FILE" ]] || return 0
  awk -v k="$1" 'index($0, k"=") == 1 { print substr($0, length(k) + 2); exit }' \
    "$ENV_FILE" 2>/dev/null || true
}

# Print KEY from validator.env with all whitespace stripped and a default fallback.
# Use for config values (ports, IPs, repo slugs); use env_get_raw for secrets
# where a legitimate space must be preserved.
env_get() {
  local value
  value="$(env_get_raw "$1")"
  value="${value//[[:space:]]/}"
  printf '%s\n' "${value:-${2:-}}"
}

# True if validator.env has `KEY=<non-empty>`.
env_has_value() {
  [[ -f "$ENV_FILE" ]] || return 1
  local value
  value="$(env_get_raw "$1")"
  [[ -n "$value" ]]
}

# Prompt silently for VAR if not set in the environment and not present in validator.env.
# On success, exports VAR so child processes (_compose) pick it up. On non-TTY
# with no value available, errors out via err_non_tty.
prompt_password_if_unset() {
  local var="$1"
  # ${!var:-} = value of $<var>, empty if unset (needed under `set -u`).
  if [[ -n "${!var:-}" ]] || env_has_value "$var"; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    HANDLED_ERROR=1
    echo "Error: ${var} not set and no TTY for prompt. Set it in validator.env or the environment." >&2
    return 1
  fi
  local value
  read -r -s -p "${var}: " value
  echo ""
  export "$var=$value"
}

# ---- Preflight checks
# Each check is a standalone function; `preflight` composes them in order and
# aborts on the first failure with the canonical error.

check_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
}

# Informational: prints a one-line note if validator.env is missing. Never fails.
check_env_note() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Note: ${ENV_FILE} not found — using defaults (gnolang/gno @ master). Run 'cp validator.env.example ${ENV_FILE}' to customize." >&2
  fi
  return 0
}

check_genesis() {
  [[ -f "$GENESIS_FILE" ]]
}

# True if the keystore directory has at least one entry (user identity present).
check_keystore() {
  dir_has_entries "${GNOKMS_DATA}/keystore"
}

# True if the gnokms service is NOT running. Used by gen-identity to avoid
# lock contention on the keystore DB.
check_gnokms_not_running() {
  ! docker container inspect "$GNOKMS_CONTAINER" >/dev/null 2>&1 && return 0
  local state
  state="$(docker inspect --format '{{.State.Status}}' "$GNOKMS_CONTAINER" 2>/dev/null || echo "")"
  [[ "$state" != "running" ]]
}

# preflight <check>... — runs checks in order; on first failure, emits the
# canonical error and returns 1. The `docker_warn` pseudo-check is a soft
# variant (used by `reset`) that warns but doesn't abort.
# NOTE: `err_foo` writes to stderr and returns 1 — but we must chain with an
# explicit `return 1` (not `return "$(err_foo)"`, which would capture stdout
# and call `return ""`, causing a numeric-argument error and a double ERR trap).
preflight() {
  local check
  for check in "$@"; do
    case "$check" in
    docker)
      check_docker || {
        err_docker
        return 1
      }
      ;;
    docker_warn)
      if ! check_docker; then
        echo "Warning: Docker unavailable — can't verify container state. Ensure containers are stopped before continuing." >&2
      fi
      ;;
    env_note)
      check_env_note
      ;;
    genesis)
      check_genesis || {
        err_genesis_missing
        return 1
      }
      ;;
    keystore)
      check_keystore || {
        err_keystore_missing
        return 1
      }
      ;;
    gnokms_not_running)
      check_gnokms_not_running || {
        err_gnokms_running
        return 1
      }
      ;;
    *)
      HANDLED_ERROR=1
      echo "preflight: unknown check '$check'" >&2
      return 2
      ;;
    esac
  done
}

# ---- Input resolution
# Centralized resolution of GNO_REPO / GNO_VERSION / GNO_COMMIT_HASH and
# related values. Targets call these once and rely on the exported vars.

# Sets GNO_REPO, GNO_VERSION, GNO_COMMIT_HASH from validator.env with master
# fallback. If $1 is "skip-commit", GNO_COMMIT_HASH is left empty (used by
# targets that don't need a commit, e.g. stop/logs).
resolve_gno_inputs() {
  local skip_commit="${1:-}"
  local repo version commit
  repo="$(env_get GNO_REPO gnolang/gno)"
  version="$(env_get GNO_VERSION master)"
  export GNO_REPO="$repo"
  export GNO_VERSION="$version"
  if [[ "$skip_commit" == "skip-commit" ]]; then
    export GNO_COMMIT_HASH=""
    return 0
  fi
  commit="$(git ls-remote "https://github.com/${repo}.git" "$version" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  if [[ -z "$commit" ]]; then
    # Offline or bad ref — fall back to the version string so downstream can
    # still populate labels and attempt builds from a possibly-cached clone.
    # Upstream-commit drift can't be detected in this mode; warn so the operator
    # knows not to trust a "no drift" answer on this run.
    echo "Warning: could not resolve ${version} on ${repo} to a commit hash (offline or invalid ref). Using version string as commit; upstream-commit drift won't be detected." >&2
    commit="$version"
  fi
  export GNO_COMMIT_HASH="$commit"
}

# Sets GNOLAND_RPC_LADDR, GNOLAND_RPC_PORT, GNOLAND_P2P_LADDR, GNOLAND_P2P_PORT
# from validator.env with documented defaults.
resolve_ports() {
  export GNOLAND_RPC_LADDR="$(env_get GNOLAND_RPC_LADDR 0.0.0.0)"
  export GNOLAND_RPC_PORT="$(env_get GNOLAND_RPC_PORT 26657)"
  export GNOLAND_P2P_LADDR="$(env_get GNOLAND_P2P_LADDR 0.0.0.0)"
  export GNOLAND_P2P_PORT="$(env_get GNOLAND_P2P_PORT 26656)"
}

# Sets CONFIG_OVERRIDES_SHA256, VALIDATOR_ENV_SHA256, COMPOSE_FILE_SHA256.
# Empty string if a file is absent — compose's ${VAR:-} fallback then leaves
# the corresponding label empty on the gnoland container.
resolve_input_hashes() {
  export CONFIG_OVERRIDES_SHA256=""
  export VALIDATOR_ENV_SHA256=""
  export COMPOSE_FILE_SHA256=""
  [[ -f "$OVERRIDES_FILE" ]] && CONFIG_OVERRIDES_SHA256="$(sha256_of_file "$OVERRIDES_FILE")"
  [[ -f "$ENV_FILE" ]] && VALIDATOR_ENV_SHA256="$(sha256_of_file "$ENV_FILE")"
  [[ -f "$COMPOSE_FILE" ]] && COMPOSE_FILE_SHA256="$(sha256_of_file "$COMPOSE_FILE")"
}

# ---- Docker helpers

# Build SERVICE's image with `_compose` if IMAGE is missing locally.
# Used by commands that invoke the image directly (outside _compose).
ensure_image() {
  local image="$1" service="$2"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Building ${service} image, please wait..."
    cmd_build
  fi
}

# Run the gnoland image once with the data volume, as the host user, and with
# config.overrides mounted read-only if present. Entry point is the default
# (gnoland-entrypoint.sh), so passing `gnoland <subcommand>` works as expected.
gnoland_run() {
  local args=(
    --rm
    --user "${HOST_UID}:${HOST_GID}"
    -v "${PROJECT_ROOT}/${GNOLAND_DATA}:/gnoland-data"
  )
  if [[ -f "$OVERRIDES_FILE" ]]; then
    args+=(-v "${PROJECT_ROOT}/${OVERRIDES_FILE}:/config.overrides:ro")
  fi
  docker run "${args[@]}" "$GNOLAND_IMAGE" "$@"
}

# Print a Docker image label (empty if missing or image absent).
image_label() {
  docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true
}

# Print a Docker container label (empty if missing or container absent).
container_label() {
  docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true
}

# Print SHA-256 of a local file (portable across Linux and macOS).
sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# True if DIR exists and contains at least one entry. Uses `find -quit` to
# avoid parsing `ls` output. Portable across GNU and BSD find.
dir_has_entries() {
  [[ -d "$1" ]] || return 1
  [[ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

# ---- Container state classification
# classify_state populates globals describing each service's state. Targets
# branch on these instead of issuing ad-hoc `docker container inspect`.
#
# STATE_<SVC>           — one of: absent | created | running | restarting | stopped
# STATE_STARTED_AT_<SVC>— epoch seconds (0 if absent or never started)
# STATE_OVERALL         — none (all absent) | running (any running) |
#                         restarting (any restarting) | stopped (all present, none running)
#                         | mixed (present+absent mix with at least one running)

_classify_one() {
  local container="$1" var="$2" started_var="$3"
  local state iso epoch
  if ! docker container inspect "$container" >/dev/null 2>&1; then
    printf -v "$var" '%s' "absent"
    printf -v "$started_var" '%s' "0"
    return
  fi
  state="$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")"
  iso="$(docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null || echo "")"
  epoch="$(iso_to_epoch "$iso")"
  case "$state" in
  running) printf -v "$var" '%s' "running" ;;
  restarting) printf -v "$var" '%s' "restarting" ;;
  exited | created | paused | dead) printf -v "$var" '%s' "stopped" ;;
  *) printf -v "$var" '%s' "stopped" ;;
  esac
  printf -v "$started_var" '%s' "$epoch"
}

classify_state() {
  _classify_one "$GNOLAND_CONTAINER" STATE_GNOLAND STATE_STARTED_AT_GNOLAND
  _classify_one "$GNOKMS_CONTAINER" STATE_GNOKMS STATE_STARTED_AT_GNOKMS
  _classify_one "$SENTINEL_CONTAINER" STATE_SENTINEL STATE_STARTED_AT_SENTINEL

  local present=0 running=0 restarting=0
  local svc
  for svc in GNOLAND GNOKMS SENTINEL; do
    local v="STATE_${svc}"
    case "${!v}" in
    absent) ;;
    running)
      present=$((present + 1))
      running=$((running + 1))
      ;;
    restarting)
      present=$((present + 1))
      restarting=$((restarting + 1))
      ;;
    *) present=$((present + 1)) ;;
    esac
  done

  if ((present == 0)); then
    STATE_OVERALL=none
  elif ((restarting > 0)); then
    STATE_OVERALL=restarting
  elif ((running == 0)); then
    STATE_OVERALL=stopped
  elif ((running == present)); then
    STATE_OVERALL=running
  else
    STATE_OVERALL=mixed
  fi
  export STATE_OVERALL
}

# ---- Sentinel image helpers

sentinel_image_ref() {
  local tag
  tag="$(env_get SENTINEL_IMAGE_TAG latest)"
  printf 'ghcr.io/aeddi/gno-watchtower/sentinel:%s\n' "$tag"
}

sentinel_tag_is_digest() {
  local tag
  tag="$(env_get SENTINEL_IMAGE_TAG latest)"
  [[ "$tag" == sha256:* ]]
}

sentinel_remote_digest() {
  local ref
  ref="$(sentinel_image_ref)"
  local out
  out="$(docker manifest inspect "$ref" 2>/dev/null || true)"
  [[ -z "$out" ]] && return 0
  local digest=""
  local jq_bin
  if jq_bin="$(ensure_jq 2>/dev/null)" && [[ -n "$jq_bin" ]]; then
    digest="$(printf '%s' "$out" | "$jq_bin" -r '.manifests[0].digest // .config.digest // empty' 2>/dev/null || true)"
  fi
  if [[ -z "$digest" ]]; then
    digest="$(printf '%s' "$out" | grep -m1 -Eo 'sha256:[a-f0-9]{64}' || true)"
  fi
  printf '%s\n' "$digest"
}

sentinel_local_digest() {
  local ref
  ref="$(sentinel_image_ref)"
  docker image inspect --format '{{index .RepoDigests 0}}' "$ref" 2>/dev/null |
    grep -Eo 'sha256:[a-f0-9]{64}' | head -1 || true
}

sentinel_pull() {
  local ref
  ref="$(sentinel_image_ref)"
  echo "Pulling ${ref}..."
  docker pull "$ref"
}

# Print the sentinel binary's reported version string by running `sentinel
# version` inside the configured image. Requires the image to be locally
# present — does not auto-pull to avoid slow surprises inside cmd_infos.
sentinel_version() {
  local ref
  ref="$(sentinel_image_ref)"
  docker image inspect "$ref" >/dev/null 2>&1 || return 1
  docker run --rm --entrypoint sentinel "$ref" version 2>/dev/null
}

# ---- Image tag + content-hash helpers

compute_content_hash() {
  local hash_tool
  if command -v sha256sum >/dev/null 2>&1; then
    hash_tool=sha256sum
  else
    hash_tool="shasum -a 256"
  fi
  # `cat` is load-bearing: we hash the concatenation of all inputs, not the
  # per-file digests `sha256sum file1 file2` would emit.
  # shellcheck disable=SC2086 # hash_tool may be "shasum -a 256" — must word-split
  cat "$@" | $hash_tool | cut -c1-8
}

content_hash_for() {
  local kind="$1"
  case "$kind" in
  gnokms) compute_content_hash Dockerfile docker/gnokms-entrypoint.sh ;;
  gnoland) compute_content_hash Dockerfile docker/gnoland-entrypoint.sh ;;
  *)
    echo "content_hash_for: unknown kind '$kind'" >&2
    return 1
    ;;
  esac
}

image_tag_for() {
  local kind="$1" commit="$2"
  local content
  content="$(content_hash_for "$kind")"
  printf '%s-%s\n' "${commit:0:12}" "$content"
}

# ---- Build state

write_build_state() {
  local out_file="$STATE_FILE"
  local build_date gnokms_content gnoland_content gnokms_image gnoland_image
  local sentinel_ref sentinel_digest
  build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gnokms_content="$(content_hash_for gnokms)"
  gnoland_content="$(content_hash_for gnoland)"
  gnokms_image="${GNOKMS_IMAGE}:$(image_tag_for gnokms "$GNO_COMMIT_HASH")"
  gnoland_image="${GNOLAND_IMAGE}:$(image_tag_for gnoland "$GNO_COMMIT_HASH")"
  sentinel_ref="$(sentinel_image_ref)"
  sentinel_digest="$(sentinel_local_digest)"
  [[ -z "$sentinel_digest" ]] && sentinel_digest="$(sentinel_remote_digest)"

  local tmp
  tmp="$(mktemp "${out_file}.tmp.XXXXXX")" || return 1

  if ! {
    echo "# Build state snapshot — inputs used when images were last built."
    echo "# Compared by 'make start' and 'make update' to detect drift."
    echo "# Do not edit by hand — regenerated by 'make build'."
    echo ""
    echo "BUILD_DATE=\"${build_date}\""
    echo ""
    echo "GNO_REPO=\"${GNO_REPO}\""
    echo "GNO_VERSION=\"${GNO_VERSION}\""
    echo "GNO_COMMIT=\"${GNO_COMMIT_HASH}\""
    echo ""
    echo "GNOKMS_CONTENT_HASH=\"${gnokms_content}\""
    echo "GNOLAND_CONTENT_HASH=\"${gnoland_content}\""
    echo ""
    echo "GNOKMS_IMAGE_TAG=\"${gnokms_image}\""
    echo "GNOLAND_IMAGE_TAG=\"${gnoland_image}\""
    echo ""
    echo "SENTINEL_IMAGE_REF=\"${sentinel_ref}\""
    echo "SENTINEL_IMAGE_DIGEST=\"${sentinel_digest}\""
  } >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$out_file" || {
    rm -f "$tmp"
    return 1
  }
}

# Parse the build state file line by line (never `source` it — that would
# execute any code dropped into the file by a lower-trust process). Keys are
# validated against a strict regex so they can't inject shell syntax; values
# are passed through `printf '%q'` to re-quote safely before the caller evals.
read_build_state_as_prev() {
  [[ -f "$STATE_FILE" ]] || return 1
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
    '' | '#'*) continue ;;
    esac
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=\"(.*)\"$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      printf 'PREV_%s=%q\n' "$key" "$value"
    fi
  done <"$STATE_FILE"
}

# Prints a summary of image-level drift (gno repo/version/commit + content)
# to stdout. Does NOT cover sentinel — callers use `sentinel_drift_summary`
# for that so update's need_rebuild / need_sentinel_pull flags stay distinct.
# Returns 0 when clean, 1 when drift detected. Expects PREV_* loaded and
# GNO_REPO/GNO_VERSION/GNO_COMMIT_HASH set.
build_state_drift_summary() {
  local drift=0

  if [[ "${PREV_GNO_REPO:-}" != "${GNO_REPO:-}" ]]; then
    echo "  gno repo changed: ${PREV_GNO_REPO:-<none>} → ${GNO_REPO:-<none>}"
    drift=1
  elif [[ "${PREV_GNO_VERSION:-}" != "${GNO_VERSION:-}" ]]; then
    echo "  gno ref changed: ${PREV_GNO_VERSION:-<none>} → ${GNO_VERSION:-<none>}"
    drift=1
  elif [[ -n "${GNO_COMMIT_HASH:-}" && "${PREV_GNO_COMMIT:-}" != "${GNO_COMMIT_HASH}" ]]; then
    # Only compare commits when the caller resolved one (via the full
    # `resolve_gno_inputs`). Lightweight callers (infos/status/start) use
    # skip-commit to avoid a network round-trip per tick; they still detect
    # validator.env edits via the repo/version comparisons above.
    echo "  gno commit advanced on ${GNO_VERSION}: ${PREV_GNO_COMMIT:0:12} → ${GNO_COMMIT_HASH:0:12}"
    drift=1
  fi

  local curr_gnokms curr_gnoland
  curr_gnokms="$(content_hash_for gnokms)"
  curr_gnoland="$(content_hash_for gnoland)"
  if [[ "${PREV_GNOKMS_CONTENT_HASH:-}" != "${curr_gnokms}" ]]; then
    echo "  gnokms image content changed (Dockerfile or docker/gnokms-entrypoint.sh)"
    drift=1
  fi
  if [[ "${PREV_GNOLAND_CONTENT_HASH:-}" != "${curr_gnoland}" ]]; then
    echo "  gnoland image content changed (Dockerfile or docker/gnoland-entrypoint.sh)"
    drift=1
  fi

  return "$drift"
}

# Prints a summary of sentinel-image drift. Returns 0 when clean, 1 when drift
# detected (or when the remote is unreachable — treated as clean). Expects
# PREV_* loaded via read_build_state_as_prev.
sentinel_drift_summary() {
  sentinel_tag_is_digest && return 0
  local curr_sentinel_ref curr_remote
  curr_sentinel_ref="$(sentinel_image_ref)"
  curr_remote="$(sentinel_remote_digest)"
  [[ -z "$curr_remote" ]] && return 0

  if [[ "${PREV_SENTINEL_IMAGE_REF:-}" != "${curr_sentinel_ref}" ]]; then
    echo "  sentinel image tag changed: ${PREV_SENTINEL_IMAGE_REF:-<none>} → ${curr_sentinel_ref}"
    return 1
  fi
  if [[ -n "${PREV_SENTINEL_IMAGE_DIGEST:-}" &&
    "${PREV_SENTINEL_IMAGE_DIGEST}" != "${curr_remote}" ]]; then
    local prev_short="${PREV_SENTINEL_IMAGE_DIGEST#sha256:}"
    local curr_short="${curr_remote#sha256:}"
    echo "  sentinel image advanced on ${curr_sentinel_ref##*:}: ${prev_short:0:12} → ${curr_short:0:12}"
    return 1
  fi
  return 0
}

# ---- Drift helpers (time/file comparison)

mtime_epoch() {
  [[ -e "$1" ]] || {
    echo 0
    return
  }
  case "$UNAME_S" in
  Darwin | *BSD) stat -f %m "$1" ;;
  *) stat -c %Y "$1" ;;
  esac
}

iso_to_epoch() {
  local iso="$1"
  [[ -n "$iso" ]] || {
    echo 0
    return
  }
  local normalized="${iso%%.*}"
  normalized="${normalized%%+*}"
  normalized="${normalized%Z}"
  if date --version >/dev/null 2>&1; then
    date -u -d "${normalized}Z" +%s 2>/dev/null || echo 0
  else
    date -u -j -f "%Y-%m-%dT%H:%M:%S" "$normalized" +%s 2>/dev/null || echo 0
  fi
}

docker_time_epoch() {
  local ref="$1" path="$2" iso
  iso="$(docker inspect --format "{{${path}}}" "$ref" 2>/dev/null || true)"
  iso_to_epoch "$iso"
}

file_newer_than_docker() {
  local file="$1" ref="$2" path="$3"
  local file_mtime docker_mtime
  file_mtime="$(mtime_epoch "$file")"
  docker_mtime="$(docker_time_epoch "$ref" "$path")"
  ((file_mtime > docker_mtime))
}

# ---- Drift analysis & warning
# drift_analyze populates DRIFT_* globals describing every dimension of drift
# between the local filesystem and what is currently baked into images /
# containers. drift_warn reads those globals and prints a single formatted
# block suggesting `make update` or `make restart` as appropriate.
#
# DRIFT_IMAGES_SUMMARY  — image/sentinel drift summary (from build_state_drift_summary)
# DRIFT_IMAGES          — 0/1 flag
# DRIFT_OVERRIDES       — 0/1 — config.overrides changed since last applied
# DRIFT_ENV             — 0/1 — validator.env changed since last container create
# DRIFT_COMPOSE         — 0/1 — docker-compose.yml changed since last container create

drift_analyze() {
  DRIFT_IMAGES=0
  DRIFT_IMAGES_SUMMARY=""
  DRIFT_SENTINEL=0
  DRIFT_SENTINEL_SUMMARY=""
  DRIFT_OVERRIDES=0
  DRIFT_ENV=0
  DRIFT_COMPOSE=0

  # Ensure GNO_REPO / GNO_VERSION are set so build_state_drift_summary has
  # current values to compare against. skip-commit avoids a `git ls-remote`
  # round-trip on every status tick; callers that need upstream-commit drift
  # (cmd_update) call resolve_gno_inputs (full) themselves before this.
  if [[ -z "${GNO_REPO:-}" || -z "${GNO_VERSION:-}" ]]; then
    resolve_gno_inputs skip-commit
  fi

  # Image (gno ref + content) and sentinel drift, via .build-state comparison.
  local prev_state
  if prev_state="$(read_build_state_as_prev 2>/dev/null)"; then
    eval "$prev_state"
    local img_summary sen_summary img_drift=0 sen_drift=0
    img_summary="$(build_state_drift_summary)" || img_drift=$?
    if ((img_drift == 1)); then
      DRIFT_IMAGES=1
      DRIFT_IMAGES_SUMMARY="$img_summary"
    fi
    sen_summary="$(sentinel_drift_summary)" || sen_drift=$?
    if ((sen_drift == 1)); then
      DRIFT_SENTINEL=1
      DRIFT_SENTINEL_SUMMARY="$sen_summary"
    fi
  fi

  # Container-baked state (validator.env / compose) — compared via labels when
  # available, else fall back to mtime. Only meaningful when the gnoland
  # container exists.
  if docker container inspect "$GNOLAND_CONTAINER" >/dev/null 2>&1; then
    local env_label compose_label curr_env curr_compose
    env_label="$(container_label "$GNOLAND_CONTAINER" gno-validator.validator-env.sha256)"
    compose_label="$(container_label "$GNOLAND_CONTAINER" gno-validator.compose-file.sha256)"
    curr_env=""
    curr_compose=""
    [[ -f "$ENV_FILE" ]] && curr_env="$(sha256_of_file "$ENV_FILE")"
    [[ -f "$COMPOSE_FILE" ]] && curr_compose="$(sha256_of_file "$COMPOSE_FILE")"

    if [[ -n "$env_label" ]]; then
      [[ "$env_label" != "$curr_env" ]] && DRIFT_ENV=1
    else
      # Legacy container without labels — fall back to mtime.
      if [[ -f "$ENV_FILE" ]] && file_newer_than_docker "$ENV_FILE" "$GNOLAND_CONTAINER" .Created; then
        DRIFT_ENV=1
      fi
    fi

    if [[ -n "$compose_label" ]]; then
      [[ "$compose_label" != "$curr_compose" ]] && DRIFT_COMPOSE=1
    else
      if [[ -f "$COMPOSE_FILE" ]] && file_newer_than_docker "$COMPOSE_FILE" "$GNOLAND_CONTAINER" .Created; then
        DRIFT_COMPOSE=1
      fi
    fi
  fi

  # Applied-overrides drift — written by the entrypoint after do_init().
  # When the file is absent, compare against the hash of an empty file (same
  # value the entrypoint writes when /config.overrides is missing).
  local curr_overrides=""
  if [[ -f "$OVERRIDES_FILE" ]]; then
    curr_overrides="$(sha256_of_file "$OVERRIDES_FILE")"
  else
    curr_overrides="$(sha256_of_file /dev/null)"
  fi
  if [[ -f "$APPLIED_OVERRIDES_FILE" ]]; then
    local applied
    applied="$(awk '{print $1; exit}' "$APPLIED_OVERRIDES_FILE" 2>/dev/null || echo "")"
    if [[ -n "$applied" && "$applied" != "$curr_overrides" ]]; then
      DRIFT_OVERRIDES=1
    fi
  else
    # Legacy: fall back to mtime against container .StartedAt if container exists.
    if [[ -f "$OVERRIDES_FILE" ]] && docker container inspect "$GNOLAND_CONTAINER" >/dev/null 2>&1; then
      if file_newer_than_docker "$OVERRIDES_FILE" "$GNOLAND_CONTAINER" .State.StartedAt; then
        DRIFT_OVERRIDES=1
      fi
    fi
  fi

  export DRIFT_IMAGES DRIFT_IMAGES_SUMMARY DRIFT_SENTINEL DRIFT_SENTINEL_SUMMARY
  export DRIFT_OVERRIDES DRIFT_ENV DRIFT_COMPOSE
}

# Prints a grouped drift warning. Silent when no drift. Expects drift_analyze
# to have run first.
drift_warn() {
  local update_bucket="" restart_bucket=""

  if ((DRIFT_IMAGES == 1)) && [[ -n "$DRIFT_IMAGES_SUMMARY" ]]; then
    update_bucket+="${DRIFT_IMAGES_SUMMARY}"$'\n'
  fi
  if ((DRIFT_SENTINEL == 1)) && [[ -n "$DRIFT_SENTINEL_SUMMARY" ]]; then
    update_bucket+="${DRIFT_SENTINEL_SUMMARY}"$'\n'
  fi
  if ((DRIFT_ENV == 1)); then
    update_bucket+="  validator.env modified since last container create"$'\n'
  fi
  if ((DRIFT_COMPOSE == 1)); then
    update_bucket+="  docker-compose.yml modified since last container create"$'\n'
  fi
  if ((DRIFT_OVERRIDES == 1)); then
    restart_bucket+="  config.overrides modified since last container start"$'\n'
  fi

  if [[ -z "$update_bucket" && -z "$restart_bucket" ]]; then
    return 0
  fi

  echo "Warning: node is running with outdated inputs."
  if [[ -n "$update_bucket" ]]; then
    echo "Changes since last build — run 'make update':"
    printf '%s' "$update_bucket"
  fi
  if [[ -n "$restart_bucket" ]]; then
    echo "Changes since last container start — run 'make restart':"
    printf '%s' "$restart_bucket"
  fi
  echo ""
}

# ---- Image ensure
# Consolidated entry point for "make sure images are ready" logic. One mode per
# target's needs:
#   build-if-missing   — build only when an image is absent (infos, gen-identity)
#   warn-if-stale      — build-if-missing + emit drift_warn on stale images (start, restart, status)
#   rebuild-if-drift   — used by update/force=1 to unconditionally rebuild

ensure_images() {
  local mode="${1:-build-if-missing}"
  local gnokms_present=1 gnoland_present=1
  docker image inspect "$GNOKMS_IMAGE" >/dev/null 2>&1 || gnokms_present=0
  docker image inspect "$GNOLAND_IMAGE" >/dev/null 2>&1 || gnoland_present=0

  if ((gnokms_present == 0)) || ((gnoland_present == 0)); then
    echo "Building required images..."
    cmd_build
    echo ""
    return 0
  fi

  case "$mode" in
  build-if-missing) return 0 ;;
  warn-if-stale)
    drift_analyze
    drift_warn
    return 0
    ;;
  rebuild-if-drift)
    FORCE=1 cmd_build
    return 0
    ;;
  *)
    HANDLED_ERROR=1
    echo "ensure_images: unknown mode '$mode'" >&2
    return 2
    ;;
  esac
}

# ---- Password ensure
# Prompt if unset, then validate by running gnokms' `check` subcommand in a
# throwaway container. On mismatch, err_password_mismatch.
# $1 ("best-effort") makes the check non-fatal — used by stopped-container
# fast-path where the operator opted to let gnokms crash-loop on mismatch.

ensure_password() {
  local mode="${1:-strict}"
  # Best-effort + non-TTY + no password source → skip silently. The already-
  # created container has its env baked from a previous up -d, so it will
  # start fine; a wrong password would crash-loop the container (operator
  # opted in to this tradeoff for the stopped-fast-path).
  if [[ "$mode" == "best-effort" ]]; then
    if [[ -z "${GNOKMS_PASSWORD:-}" ]] && ! env_has_value GNOKMS_PASSWORD && [[ ! -t 0 ]]; then
      echo "Note: GNOKMS_PASSWORD not available (non-interactive) — skipping keystore validation." >&2
      return 0
    fi
  fi
  prompt_password_if_unset GNOKMS_PASSWORD || return 1
  if _compose run --rm --no-deps -T gnokms check >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$mode" == "best-effort" ]]; then
    echo "Warning: GNOKMS_PASSWORD validation was inconclusive. Continuing; gnokms will crash-loop if the password is wrong." >&2
    return 0
  fi
  err_password_mismatch
}

# ---- Shared prompts
# confirm "<question>" <default:y|n> <non-tty-flag-hint>
#   default=y → [Y/n], empty answer → yes.
#   default=n → [y/N], empty answer → no.
#   Non-TTY: err_non_tty <flag-hint> (non-zero exit).
# Returns 0 on yes, 1 on no.

confirm() {
  local question="$1" default="${2:-n}" flag="${3:-yes=1}"
  local prompt
  case "$default" in
  y | Y) prompt="[Y/n]" ;;
  *) prompt="[y/N]" ;;
  esac
  if [[ ! -t 0 ]]; then
    err_non_tty "$flag"
    return 1
  fi
  local answer
  read -r -p "${question} ${prompt} " answer || true
  if [[ -z "$answer" ]]; then
    case "$default" in
    y | Y) return 0 ;;
    *) return 1 ;;
    esac
  fi
  case "$answer" in
  y | Y | yes | YES) return 0 ;;
  *) return 1 ;;
  esac
}

# ---- Init gnoland data (no start)
# Runs the same entrypoint code path as `make start` but exits before gnoland
# actually starts. Used by `make infos` on uninitialized gnoland-data.

init_gnoland_data() {
  mkdir -p "${GNOLAND_DATA}/config" "${GNOLAND_DATA}/secrets"
  local args=(
    --rm
    --user "${HOST_UID}:${HOST_GID}"
    -e GNOLAND_INIT_ONLY=1
    -v "${PROJECT_ROOT}/${GNOLAND_DATA}:/gnoland-data"
  )
  if [[ -f "$OVERRIDES_FILE" ]]; then
    args+=(-v "${PROJECT_ROOT}/${OVERRIDES_FILE}:/config.overrides:ro")
  fi
  docker run "${args[@]}" "$GNOLAND_IMAGE" >/dev/null
}

# ---- Tool installers

_download_url() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url"
  else
    echo "Error: curl or wget is required to download ${url}" >&2
    return 1
  fi
}

install_lnav() {
  [[ -x "$LNAV_BIN" ]] && return 0

  if ! command -v unzip >/dev/null 2>&1; then
    echo "Error: unzip is required to extract lnav" >&2
    return 1
  fi
  local os arch archive
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}/${arch}" in
  Darwin/arm64) archive="lnav-${LNAV_VERSION}-aarch64-macos.zip" ;;
  Darwin/*) archive="lnav-${LNAV_VERSION}-x86_64-macos.zip" ;;
  Linux/aarch64) archive="lnav-${LNAV_VERSION}-linux-musl-arm64.zip" ;;
  Linux/*) archive="lnav-${LNAV_VERSION}-linux-musl-x86_64.zip" ;;
  *)
    echo "Error: unsupported platform ${os}/${arch} for lnav" >&2
    return 1
    ;;
  esac

  mkdir -p "$TOOLS_BIN_DIR"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local rc=0
  echo "Downloading lnav v${LNAV_VERSION}..." >&2
  if ! _download_url \
    "https://github.com/tstack/lnav/releases/download/v${LNAV_VERSION}/${archive}" \
    "${tmpdir}/lnav.zip"; then
    rc=1
  elif ! unzip -q "${tmpdir}/lnav.zip" "lnav-${LNAV_VERSION}/lnav" -d "$tmpdir"; then
    rc=1
  else
    mv "${tmpdir}/lnav-${LNAV_VERSION}/lnav" "$LNAV_BIN"
    chmod +x "$LNAV_BIN"
    echo "lnav installed at ${LNAV_BIN}" >&2
  fi
  rm -rf "$tmpdir"
  return "$rc"
}

install_jq() {
  [[ -x "$JQ_BIN" ]] && return 0

  local os arch asset
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}/${arch}" in
  Darwin/arm64) asset="jq-macos-arm64" ;;
  Darwin/x86_64) asset="jq-macos-amd64" ;;
  Linux/aarch64 | Linux/arm64) asset="jq-linux-arm64" ;;
  Linux/x86_64) asset="jq-linux-amd64" ;;
  *)
    echo "Error: unsupported platform ${os}/${arch} for jq" >&2
    return 1
    ;;
  esac

  mkdir -p "$TOOLS_BIN_DIR"
  local tmp
  tmp="$(mktemp "${JQ_BIN}.XXXXXX")"
  echo "Downloading jq v${JQ_VERSION}..." >&2
  if ! _download_url \
    "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${asset}" \
    "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod +x "$tmp"
  mv -f "$tmp" "$JQ_BIN"
  echo "jq installed at ${JQ_BIN}" >&2
}

ensure_jq() {
  if [[ -x "$JQ_BIN" ]]; then
    printf '%s\n' "$JQ_BIN"
    return 0
  fi
  local sys_jq
  if sys_jq="$(command -v jq 2>/dev/null)" && [[ -n "$sys_jq" ]]; then
    printf '%s\n' "$sys_jq"
    return 0
  fi
  if install_jq; then
    printf '%s\n' "$JQ_BIN"
    return 0
  fi
  return 1
}

# ---- Lifecycle helpers

# Create-and-start the containers from scratch. Used by cmd_start on first run,
# and by cmd_update after containers are torn down.
_fresh_up() {
  # Caller has already verified validator.env presence / fallback behaviour.
  ensure_password
  resolve_input_hashes
  _compose up -d

  cat <<EOF

Started. The gnoland entrypoint regenerates config on every start:
  1. resets ${GNOLAND_DATA}/config/config.toml to defaults
  2. applies user-defined overrides from ./${OVERRIDES_FILE}
  3. applies hardcoded overrides (p2p.laddr, rpc.laddr, remote signer, telemetry)
EOF
}

# ---- Commands

cmd_gen_identity() {
  preflight docker env_note gnokms_not_running
  ensure_image "$GNOKMS_IMAGE" gnokms
  drift_analyze
  drift_warn
  mkdir -p "${GNOKMS_DATA}/keystore"

  local password="${GNOKMS_PASSWORD:-}"
  [[ -z "$password" ]] && password="$(env_get_raw GNOKMS_PASSWORD)"
  if [[ -z "$password" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Error: GNOKMS_PASSWORD not set and no TTY for prompt. Set it in validator.env or the environment." >&2
      return 1
    fi
    read -r -s -p "GNOKMS_PASSWORD: " password
    echo ""
  fi

  # gnokey prompts twice for confirmation — feed the password on both lines.
  # Let gnokey handle existing-key cases via its own "overwrite?" prompt.
  printf '%s\n%s\n' "$password" "$password" |
    docker run --rm -i \
      --user "${HOST_UID}:${HOST_GID}" \
      --entrypoint gnokey \
      -v "${PROJECT_ROOT}/${GNOKMS_DATA}:/gnokms-data" \
      "$GNOKMS_IMAGE" \
      add "$GNOKMS_KEYNAME" --home /gnokms-data/keystore --insecure-password-stdin

  echo ""
  echo "Identity created. Current keystore contents:"
  docker run --rm \
    --entrypoint gnokey \
    -v "${PROJECT_ROOT}/${GNOKMS_DATA}:/gnokms-data" \
    "$GNOKMS_IMAGE" \
    list --home /gnokms-data/keystore 2>/dev/null | awk '
      { for (i = 1; i <= NF; i++) {
          if ($i == "addr:") addr = $(i+1)
          if ($i == "pub:") { pub = $(i+1); sub(/,$/, "", pub) }
      }}
      END { print "  address: " addr; print "  pub_key: " pub }'
  echo ""
  echo "Next: edit validator.env (moniker, peers, etc.) and run 'make start'."
}

# Print one data field, or a degraded `(unavailable — <reason>)` on failure.
# Keeps cmd_infos printing the rest of the node info even if a single call
# (e.g. gnoland config get) misbehaves. The reason string should tell the
# operator what's wrong and what to do about it.
# Args: <label> <reason-if-fails> <command...>
_infos_field() {
  local label="$1" reason="$2"
  shift 2
  local value
  if value="$("$@" 2>/dev/null)" && [[ -n "$value" ]]; then
    printf '%-18s %s\n' "${label}:" "$value"
  else
    printf '%-18s (unavailable — %s)\n' "${label}:" "$reason"
  fi
}

# Like _infos_field but truncates the value to <maxlen> characters (useful for
# long fingerprints where a 12-char prefix is enough to compare visually).
# Args: <label> <reason-if-fails> <maxlen> <command...>
_infos_field_trunc() {
  local label="$1" reason="$2" maxlen="$3"
  shift 3
  local value
  if value="$("$@" 2>/dev/null)" && [[ -n "$value" ]]; then
    printf '%-18s %s\n' "${label}:" "${value:0:$maxlen}"
  else
    printf '%-18s (unavailable — %s)\n' "${label}:" "$reason"
  fi
}

cmd_infos() {
  preflight docker env_note
  ensure_images warn-if-stale

  # Initialize gnoland-data on first run so subsequent config reads succeed.
  if [[ ! -f "${GNOLAND_DATA}/config/config.toml" ]]; then
    echo "Initializing gnoland-data (first run)..."
    init_gnoland_data
    echo ""
  fi

  echo "=== Identity ==="
  local gnokey_out="" has_keys=0
  if dir_has_entries "${GNOKMS_DATA}/keystore"; then
    has_keys=1
    gnokey_out="$(docker run --rm \
      --entrypoint gnokey \
      -v "${PROJECT_ROOT}/${GNOKMS_DATA}:/gnokms-data" \
      "$GNOKMS_IMAGE" \
      list --home /gnokms-data/keystore 2>/dev/null || true)"
  fi
  if [[ -n "$gnokey_out" ]] && echo "$gnokey_out" | grep -q 'addr:'; then
    echo "$gnokey_out" | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "addr:") addr = $(i+1)
            if ($i == "pub:") { pub = $(i+1); sub(/,$/, "", pub) }
        }
    } END {
        print "validator address: " addr "\nvalidator pub_key: " pub
    }'
  elif ((!has_keys)); then
    echo "validator address: (no keystore — run 'make gen-identity')"
    echo "validator pub_key: (no keystore — run 'make gen-identity')"
  else
    classify_state
    if [[ "${STATE_GNOKMS:-absent}" == "running" ]]; then
      echo "validator address: (keystore locked by running gnokms; retry shortly)"
      echo "validator pub_key: (keystore locked by running gnokms; retry shortly)"
    else
      echo "validator address: (keystore unreadable — check permissions on ${GNOKMS_DATA}/keystore)"
      echo "validator pub_key: (keystore unreadable — check permissions on ${GNOKMS_DATA}/keystore)"
    fi
  fi
  local node_reason="gnoland throwaway run failed — check 'make logs-gnoland'"
  _infos_field "node_id" "$node_reason" gnoland_run gnoland secrets get node_id.id --raw
  _infos_field "moniker" "$node_reason" gnoland_run gnoland config get moniker --raw
  echo ""

  resolve_ports
  echo "=== Network Configuration ==="
  _infos_field "persistent peers" "$node_reason" gnoland_run gnoland config get p2p.persistent_peers --raw
  printf '%-18s tcp://%s:%s\n' "p2p listener:" "${GNOLAND_P2P_LADDR}" "${GNOLAND_P2P_PORT}"
  printf '%-18s tcp://%s:%s\n' "rpc listener:" "${GNOLAND_RPC_LADDR}" "${GNOLAND_RPC_PORT}"
  echo ""

  echo "=== Build Information ==="
  local label_reason="image label not set — rebuild with 'make update'"
  _infos_field "build date" "$label_reason" image_label "$GNOLAND_IMAGE" build.date
  _infos_field "gno commit" "$label_reason" image_label "$GNOLAND_IMAGE" gno.commit
  _infos_field "gno version" "$label_reason" image_label "$GNOLAND_IMAGE" gno.version
  _infos_field "gno repo" "$label_reason" image_label "$GNOLAND_IMAGE" gno.repo
  local sentinel_reason="sentinel image not pulled — run 'make start' or 'make update'"
  _infos_field "sentinel image" "$sentinel_reason" sentinel_image_ref
  _infos_field_trunc "sentinel digest" "$sentinel_reason" 19 sentinel_local_digest
  _infos_field "sentinel version" "$sentinel_reason" sentinel_version
  echo ""

  echo "=== File Checksums (SHA-256) ==="
  if [[ -f "$GENESIS_FILE" ]]; then
    printf '%-18s %s\n' "${GENESIS_FILE}:" "$(sha256_of_file "$GENESIS_FILE")"
  else
    printf '%-18s (not found)\n' "${GENESIS_FILE}:"
  fi
}

cmd_build() {
  preflight docker env_note
  resolve_gno_inputs

  local repo="$GNO_REPO" version="$GNO_VERSION" commit="$GNO_COMMIT_HASH"
  BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  DOCKERFILE_HASH="$(sha256_of_file Dockerfile)"
  export BUILD_DATE DOCKERFILE_HASH

  echo "Build inputs:"
  echo "  repo=${repo}  version=${version}  commit=${commit:0:12}"
  echo "  dockerfile sha256=${DOCKERFILE_HASH:0:12}"
  echo ""

  local force="${FORCE:-0}"
  if [[ "$force" != "1" ]]; then
    local prev_state prev_ok=0
    if prev_state="$(read_build_state_as_prev 2>/dev/null)"; then
      eval "$prev_state"
      prev_ok=1
    fi
    if ((prev_ok == 1)); then
      local curr_gnokms curr_gnoland
      curr_gnokms="$(content_hash_for gnokms)"
      curr_gnoland="$(content_hash_for gnoland)"
      if [[ "${PREV_GNO_COMMIT:-}" == "${commit}" &&
        "${PREV_GNO_VERSION:-}" == "${version}" &&
        "${PREV_GNO_REPO:-}" == "${repo}" &&
        "${PREV_GNOKMS_CONTENT_HASH:-}" == "${curr_gnokms}" &&
        "${PREV_GNOLAND_CONTENT_HASH:-}" == "${curr_gnoland}" ]] &&
        docker image inspect "${PREV_GNOKMS_IMAGE_TAG:-}" >/dev/null 2>&1 &&
        docker image inspect "${PREV_GNOLAND_IMAGE_TAG:-}" >/dev/null 2>&1; then
        echo "Nothing to rebuild — .build-state and images match current inputs."
        echo "  (pass force=1 to rebuild anyway)"
        return 0
      fi
    fi
  else
    echo "FORCE=1 → rebuilding both images."
  fi

  ENTRYPOINT_HASH="$(sha256_of_file docker/gnokms-entrypoint.sh)"
  export ENTRYPOINT_HASH
  echo "==> Building gnokms image..."
  if ! _compose build gnokms; then
    err_build_failed
    return 1
  fi

  ENTRYPOINT_HASH="$(sha256_of_file docker/gnoland-entrypoint.sh)"
  export ENTRYPOINT_HASH
  echo "==> Building gnoland image..."
  if ! _compose build gnoland; then
    err_build_failed
    return 1
  fi

  local gnokms_tag gnoland_tag
  gnokms_tag="$(image_tag_for gnokms "$commit")"
  gnoland_tag="$(image_tag_for gnoland "$commit")"
  docker tag "$GNOKMS_IMAGE" "${GNOKMS_IMAGE}:${gnokms_tag}"
  docker tag "$GNOLAND_IMAGE" "${GNOLAND_IMAGE}:${gnoland_tag}"
  echo ""
  echo "Tagged:"
  echo "  ${GNOKMS_IMAGE}:${gnokms_tag}"
  echo "  ${GNOLAND_IMAGE}:${gnoland_tag}"

  echo ""
  if ! sentinel_pull; then
    echo "Warning: failed to pull sentinel image. Compose will retry on start." >&2
  fi

  if ! write_build_state; then
    echo "Warning: images built but .build-state write failed. Drift detection will trigger on next run until state is written." >&2
    echo ""
    echo "Build complete."
    return 0
  fi
  echo ""
  echo "Wrote ${STATE_FILE}."
}

cmd_start() {
  preflight docker env_note genesis keystore
  classify_state
  resolve_input_hashes

  case "$STATE_OVERALL" in
  running)
    # Images obviously exist (a running container uses them) — skip ensure_images.
    # Print the steady-state line first, then the drift summary.
    echo "Containers already running."
    drift_analyze
    drift_warn
    return 0
    ;;
  none)
    # First run — build if needed, then fresh up.
    ensure_images warn-if-stale
    echo "First run: creating and starting containers..."
    _fresh_up
    ;;
  stopped | mixed | restarting)
    # Stopped fast-path — print drift once, then best-effort password check, then start.
    ensure_images warn-if-stale
    ensure_password best-effort
    echo "Starting containers (config will be regenerated from ${OVERRIDES_FILE})..."
    _compose start
    ;;
  *)
    HANDLED_ERROR=1
    echo "Error: unexpected container state '${STATE_OVERALL}'." >&2
    return 1
    ;;
  esac
}

cmd_stop() {
  preflight docker
  classify_state
  case "$STATE_OVERALL" in
  none)
    echo "No validator containers exist — nothing to stop."
    return 0
    ;;
  stopped)
    echo "Containers already stopped."
    return 0
    ;;
  esac

  # Collect running vs non-running for the summary. Pair lowercase/uppercase
  # explicitly — `${var^^}` is bash 4+, and macOS ships bash 3.2 as /bin/bash.
  local -a running_svcs=() stopped_svcs=()
  local pair svc_name var_name
  for pair in "gnoland:STATE_GNOLAND" "gnokms:STATE_GNOKMS" "sentinel:STATE_SENTINEL"; do
    svc_name="${pair%%:*}"
    var_name="${pair##*:}"
    case "${!var_name}" in
    running | restarting) running_svcs+=("$svc_name") ;;
    absent) ;;
    *) stopped_svcs+=("$svc_name") ;;
    esac
  done

  _compose_noenv stop
  if ((${#running_svcs[@]} > 0)); then
    local joined
    joined="$(printf ', %s' "${running_svcs[@]}")"
    echo "Stopped: ${joined:2}"
  fi
  if ((${#stopped_svcs[@]} > 0)); then
    local joined_s
    joined_s="$(printf ', %s' "${stopped_svcs[@]}")"
    echo "Already stopped: ${joined_s:2}"
  fi
}

cmd_restart() {
  preflight docker env_note genesis keystore
  classify_state
  if [[ "$STATE_OVERALL" == "none" ]]; then
    err_no_containers_for_restart
    return 1
  fi
  if [[ "$STATE_OVERALL" == "stopped" ]]; then
    echo "Containers already stopped; starting them."
  else
    cmd_stop
    echo ""
  fi
  cmd_start
}

cmd_logs_gnoland() {
  preflight docker
  classify_state
  case "${STATE_GNOLAND:-absent}" in
  absent)
    echo "No gnoland container yet — run 'make start'."
    return 0
    ;;
  stopped)
    echo "Container stopped — showing logs from last run. Ctrl+C to exit."
    ;;
  esac
  local since="${SINCE:-1h}"
  if install_lnav; then
    TERM=xterm-256color "$LNAV_BIN" -I ./.lnav \
      <(_compose_noenv logs --since "$since" -f gnoland 2>/dev/null)
  else
    echo "lnav unavailable, falling back to plain logs..."
    _compose_noenv logs --since "$since" -f gnoland
  fi
}

cmd_logs_gnokms() {
  preflight docker
  classify_state
  case "${STATE_GNOKMS:-absent}" in
  absent)
    echo "No gnokms container yet — run 'make start'."
    return 0
    ;;
  stopped)
    echo "Container stopped — showing logs from last run. Ctrl+C to exit."
    ;;
  esac
  local since="${SINCE:-}"
  if [[ -n "$since" ]]; then
    _compose_noenv logs --since "$since" -f gnokms
  else
    _compose_noenv logs -f gnokms
  fi
}

cmd_logs_sentinel() {
  preflight docker
  classify_state
  case "${STATE_SENTINEL:-absent}" in
  absent)
    echo "No sentinel container yet — run 'make start'."
    return 0
    ;;
  stopped)
    echo "Container stopped — showing logs from last run. Ctrl+C to exit."
    ;;
  esac
  local since="${SINCE:-}"
  if [[ -n "$since" ]]; then
    _compose_noenv logs --since "$since" -f sentinel
  else
    _compose_noenv logs -f sentinel
  fi
}

cmd_status() {
  preflight docker env_note
  classify_state
  local watch_interval="${WATCH:-}"
  resolve_ports
  local rpc_port="$GNOLAND_RPC_PORT"

  # Fast-path classifications that don't need RPC.
  case "$STATE_OVERALL" in
  none)
    echo "No containers — run 'make start'."
    return 0
    ;;
  stopped)
    echo "Containers stopped — run 'make start'."
    return 0
    ;;
  esac

  local jq_bin
  if ! jq_bin="$(ensure_jq)"; then
    echo "Warning: jq unavailable (auto-install failed). Watch mode disabled; printing raw JSON once." >&2
    _status_raw "$rpc_port"
    return 0
  fi

  if [[ -z "$watch_interval" ]]; then
    drift_analyze
    drift_warn
    _status_render "$rpc_port" "$jq_bin"
    return 0
  fi

  if ! [[ "$watch_interval" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$watch_interval" == "0" ]]; then
    HANDLED_ERROR=1
    echo "Error: watch= must be a positive number (got '${watch_interval}')." >&2
    return 2
  fi

  local eol=$'\033[K'
  (
    trap 'printf "\033[?25h\n"' EXIT INT TERM
    printf '\033[?25l'
    printf '\033[2J'
    while true; do
      classify_state
      printf '\033[H'
      printf "Refreshing every %ss (Ctrl+C to stop)${eol}\n\n" "$watch_interval"
      _status_render "$rpc_port" "$jq_bin" "$eol"
      sleep "$watch_interval"
    done
  )
}

_status_render() {
  local port="$1" jq="$2" eol="${3:-}"

  printf "%-16s %-12s %-8s %-24s %-7s %s${eol}\n" "Node" "Status" "Height" "Latest Block" "Peers" "Validator"
  printf "%-16s %-12s %-8s %-24s %-7s %s${eol}\n" "----" "------" "------" "------------" "-----" "---------"

  # Container-level classification first — it covers "restarting" and "running
  # but RPC not yet up" cases the RPC probe alone can't distinguish.
  case "${STATE_GNOLAND:-absent}" in
  restarting)
    printf "%-16s %-12s %-8s %-24s %-7s %s${eol}\n" "-" "restarting" "-" "-" "-" "(make logs-gnoland)"
    return 0
    ;;
  absent | stopped)
    printf "%-16s %-12s %-8s %-24s %-7s %s${eol}\n" "-" "${STATE_GNOLAND:-absent}" "-" "-" "-" "-"
    return 0
    ;;
  esac

  local status_json net_json
  status_json="$(_http_get "http://localhost:${port}/status" || true)"
  net_json="$(_http_get "http://localhost:${port}/net_info" || true)"

  if [[ -z "$status_json" ]]; then
    # Distinguish "just started" from "hung" using StartedAt.
    local now started age
    now="$(date -u +%s)"
    started="${STATE_STARTED_AT_GNOLAND:-0}"
    age=$((now - started))
    if ((started > 0 && age < 60)); then
      printf "%-16s %-12s %-8s %-24s %-7s %s${eol}\n" "-" "starting" "-" "-" "-" "(${age}s ago)"
    else
      printf "%-16s %-12s %-8s %-24s %-7s %s${eol}\n" "-" "unreachable" "-" "-" "-" "(make logs-gnoland)"
    fi
    return 0
  fi

  local moniker height block catching_up vp peers status validator
  moniker="$(echo "$status_json" | "$jq" -r '.result.node_info.moniker // "-"' 2>/dev/null || echo "-")"
  height="$(echo "$status_json" | "$jq" -r '.result.sync_info.latest_block_height // "-"' 2>/dev/null || echo "-")"
  block="$(echo "$status_json" | "$jq" -r '(.result.sync_info.latest_block_time // "-")[:19]' 2>/dev/null || echo "-")"
  catching_up="$(echo "$status_json" | "$jq" -r '.result.sync_info.catching_up // false' 2>/dev/null || echo "false")"
  vp="$(echo "$status_json" | "$jq" -r '.result.validator_info.voting_power // "0"' 2>/dev/null || echo "0")"
  peers="$(echo "$net_json" | "$jq" -r '.result.n_peers // "-"' 2>/dev/null || echo "-")"

  if [[ "$catching_up" == "true" ]]; then status="syncing"; else status="running"; fi
  if [[ "$vp" == "0" || -z "$vp" ]]; then validator="no"; else validator="yes (VP ${vp})"; fi

  printf "%-16s %-12s %-8s %-24s %-7s %s${eol}\n" "$moniker" "$status" "$height" "$block" "$peers" "$validator"
}

_status_raw() {
  local port="$1"
  local s n
  s="$(_http_get "http://localhost:${port}/status" || echo "{}")"
  n="$(_http_get "http://localhost:${port}/net_info" || echo "{}")"
  echo "=== /status ==="
  echo "$s"
  echo ""
  echo "=== /net_info ==="
  echo "$n"
}

_http_get() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 2 "$url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=2 "$url" 2>/dev/null
  else
    # Warn once per process so watch-mode doesn't spam. Without an HTTP client
    # the operator would otherwise see a misleading "unreachable" status line.
    if [[ -z "${_HTTP_GET_WARNED:-}" ]]; then
      echo "Warning: neither curl nor wget is installed — can't probe RPC. Install one to get real status." >&2
      _HTTP_GET_WARNED=1
    fi
    return 1
  fi
}

cmd_reset() {
  preflight docker_warn

  # Nothing-to-reset guards (cheap, before any prompt).
  if [[ ! -d "$GNOLAND_DATA" ]] || ! dir_has_entries "$GNOLAND_DATA"; then
    echo "Nothing to reset — ${GNOLAND_DATA} not initialized."
    return 0
  fi
  local pv_state="${GNOLAND_DATA}/secrets/priv_validator_state.json"
  local pv_height=""
  [[ -f "$pv_state" ]] && pv_height="$(awk -F'"' '/"height"/{print $4; exit}' "$pv_state" 2>/dev/null || true)"
  # Initialized but no chain state yet (fresh init, node never started) and
  # priv_validator_state already at height=0 → nothing to do.
  if [[ ! -d "${GNOLAND_DATA}/db" && ! -d "${GNOLAND_DATA}/wal" ]]; then
    if [[ ! -f "$pv_state" || "$pv_height" == "0" ]]; then
      echo "Already at clean state — nothing to reset."
      return 0
    fi
  fi

  # Docker state: only classify if docker was reachable.
  local was_running=0
  if check_docker; then
    classify_state
    [[ "${STATE_GNOLAND:-absent}" == "running" || "${STATE_GNOKMS:-absent}" == "running" ]] && was_running=1
  fi

  echo "About to reset chain state."
  echo "  Will delete: ${GNOLAND_DATA}/db, ${GNOLAND_DATA}/wal"
  echo "  Will reset : ${pv_state}"
  echo "  Will keep  : keystore (${GNOKMS_DATA}/), validator keys, node_id, config"

  if ! confirm "Continue?" n yes=1; then
    HANDLED_ERROR=1
    echo "Aborted."
    return 1
  fi

  if ((was_running == 1)); then
    if ! confirm "Containers are running. Stop them first?" y yes=1; then
      HANDLED_ERROR=1
      echo "Aborted — will not reset while containers are running."
      return 1
    fi
    cmd_stop
  fi

  echo "Resetting..."
  rm -rf "${GNOLAND_DATA}/db" "${GNOLAND_DATA}/wal"
  if ! printf '{\n  "height": "0",\n  "round": "0",\n  "step": 0\n}\n' >"$pv_state"; then
    HANDLED_ERROR=1
    echo "WARNING: db/wal deleted but ${pv_state} failed to reset." >&2
    echo "         The node will refuse to start until this file contains height=0. Manual fix needed." >&2
    return 1
  fi
  echo "Reset complete."

  if ((was_running == 1)); then
    if confirm "Start containers again?" y yes=1; then
      cmd_start
    else
      echo "Run 'make start' when ready."
    fi
  else
    echo "Run 'make start' when ready."
  fi
}

# List all locally built gno-validator image tags (both repositories).
_list_validator_images() {
  {
    docker images --format '{{.Repository}}:{{.Tag}}' "$GNOKMS_IMAGE"
    docker images --format '{{.Repository}}:{{.Tag}}' "$GNOLAND_IMAGE"
  } | sort -u
}

# List sentinel images present locally.
_list_sentinel_images() {
  docker images --format '{{.Repository}}:{{.Tag}}' 'ghcr.io/aeddi/gno-watchtower/sentinel' | sort -u
}

# Given a list of gnokms/gnoland tags on stdin, print the ones considered
# "stale" (not matching the current content-addressed tag or :latest).
# Requires .build-state loaded as PREV_* and GNO_COMMIT_HASH resolved.
_classify_stale_tags() {
  local curr_gnokms_tag curr_gnoland_tag
  curr_gnokms_tag="${GNOKMS_IMAGE}:$(image_tag_for gnokms "$GNO_COMMIT_HASH")"
  curr_gnoland_tag="${GNOLAND_IMAGE}:$(image_tag_for gnoland "$GNO_COMMIT_HASH")"
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
    "${GNOKMS_IMAGE}:latest" | "${GNOLAND_IMAGE}:latest") ;;
    "$curr_gnokms_tag" | "$curr_gnoland_tag") ;;
    *) printf '%s\n' "$line" ;;
    esac
  done
}

cmd_clean_imgs() {
  preflight docker env_note
  local all="${ALL:-0}" skip_prompt="${YES:-0}"
  resolve_gno_inputs skip-commit

  # Gather images first.
  local -a all_images=() target_images=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && all_images+=("$line")
  done < <(_list_validator_images)

  if ((${#all_images[@]} == 0)); then
    echo "No gno-validator images present."
    return 0
  fi

  # Classify target list by mode.
  if ((all == 1)); then
    target_images=("${all_images[@]}")
    # Add sentinel images in all-mode.
    local sline
    while IFS= read -r sline; do
      [[ -n "$sline" ]] && target_images+=("$sline")
    done < <(_list_sentinel_images)
  else
    # Stale-only mode — requires .build-state to classify.
    if [[ ! -f "$STATE_FILE" ]]; then
      HANDLED_ERROR=1
      echo "Error: cannot identify stale images without ${STATE_FILE}." >&2
      echo "       Pass all=1 to remove everything, or run 'make build' first." >&2
      return 1
    fi
    # Resolve current commit so content-addressed tag matches .build-state.
    resolve_gno_inputs
    while IFS= read -r line; do
      [[ -n "$line" ]] && target_images+=("$line")
    done < <(printf '%s\n' "${all_images[@]}" | _classify_stale_tags)
    if ((${#target_images[@]} == 0)); then
      echo "No stale images — all tags match current inputs. (Pass all=1 to remove everything.)"
      return 0
    fi
  fi

  # Preempt if any container references any target image (by tag or repo).
  local -a containers_in_use=()
  local container image_ref tgt
  while IFS= read -r container; do
    [[ -z "$container" ]] && continue
    image_ref="$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)"
    for tgt in "${target_images[@]}"; do
      if [[ "$image_ref" == "$tgt" ]]; then
        containers_in_use+=("$container")
        break
      fi
    done
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
  if ((${#containers_in_use[@]} > 0)); then
    err_containers_in_use "${containers_in_use[*]}"
    return 1
  fi

  if ((all == 1)); then
    echo "Will remove ${#target_images[@]} image(s) (all, including sentinel):"
  else
    echo "Will remove ${#target_images[@]} stale image(s):"
  fi
  local i
  for i in "${target_images[@]}"; do
    echo "  - $i"
  done
  if ((all == 0)); then
    echo ""
    echo "(Pass all=1 to remove all gno-validator images, including current ones.)"
  fi
  echo ""

  if ((skip_prompt != 1)); then
    if ! confirm "Continue?" n yes=1; then
      HANDLED_ERROR=1
      echo "Aborted."
      return 1
    fi
  fi

  # Remove one-by-one so a single failure doesn't abort the batch.
  local failed=0 ok=0
  for i in "${target_images[@]}"; do
    if docker rmi -f "$i" >/dev/null 2>&1; then
      ok=$((ok + 1))
      echo "  removed: $i"
    else
      failed=$((failed + 1))
      echo "  FAILED:  $i" >&2
    fi
  done
  echo ""
  if ((failed > 0)); then
    HANDLED_ERROR=1
    echo "Removed ${ok} image(s); ${failed} failed."
    return 1
  fi
  echo "Removed ${ok} image(s)."

  if ((all == 1)); then
    rm -f "$STATE_FILE"
    echo "Deleted ${STATE_FILE} (state no longer reflects any local image)."
  fi
}

cmd_update() {
  preflight docker env_note genesis keystore
  local force="${FORCE:-0}"
  resolve_gno_inputs
  classify_state
  drift_analyze

  local need_rebuild=0 need_recreate=0 need_sentinel_pull=0
  local -a reasons=()

  if ((DRIFT_IMAGES == 1)); then
    need_rebuild=1
    reasons+=("build inputs changed since last build:")
    while IFS= read -r line; do
      [[ -n "$line" ]] && reasons+=("  ${line}")
    done <<<"$DRIFT_IMAGES_SUMMARY"
  fi

  # Sentinel drift — pull-only, no local rebuild required.
  if ((DRIFT_SENTINEL == 1)); then
    need_sentinel_pull=1
    need_recreate=1
    reasons+=("sentinel image advanced:")
    while IFS= read -r line; do
      [[ -n "$line" ]] && reasons+=("  ${line}")
    done <<<"$DRIFT_SENTINEL_SUMMARY"
  fi

  if ((DRIFT_ENV == 1)); then
    need_recreate=1
    reasons+=("${ENV_FILE} modified since containers were created")
  fi
  if ((DRIFT_COMPOSE == 1)); then
    need_recreate=1
    reasons+=("${COMPOSE_FILE} modified since containers were created")
  fi
  if [[ "$STATE_OVERALL" == "none" ]]; then
    need_recreate=1
    reasons+=("containers not yet created")
  fi

  # Rebuild implies recreate (new image → new container).
  ((need_rebuild == 1)) && need_recreate=1

  if ((need_rebuild == 0 && need_recreate == 0 && force == 0)); then
    echo "Already up to date (pass force=1 to recreate anyway)."
    return 0
  fi

  if ((force == 1)); then
    reasons+=("force=1")
    need_rebuild=1
    need_recreate=1
  fi

  echo "Update will:"
  ((need_rebuild == 1)) && echo "  - rebuild images"
  if ((need_recreate == 1)); then
    if [[ "$STATE_OVERALL" != "none" ]]; then
      echo "  - stop and recreate containers (container logs will be lost)"
    else
      echo "  - create containers"
    fi
  fi
  echo ""
  echo "Reasons:"
  local r
  for r in "${reasons[@]:-}"; do
    [[ -n "$r" ]] && echo "  - $r"
  done
  echo ""
  echo "Preserved: ${GNOLAND_DATA}/ (chain db, wal, keys, config), ${GNOKMS_DATA}/ (keystore),"
  echo "           ${GENESIS_FILE}, and named volumes (gnokms-sock)."
  echo ""

  if ((force == 0)); then
    if ! confirm "Continue?" y force=1; then
      HANDLED_ERROR=1
      echo "Aborted."
      return 1
    fi
  fi

  if ((need_rebuild == 1)); then
    cmd_build
    echo ""
  elif ((need_sentinel_pull == 1 || force == 1)); then
    if sentinel_pull; then
      write_build_state
      echo ""
    else
      echo "Warning: sentinel pull failed; compose will retry on start." >&2
    fi
  fi

  if [[ "$STATE_OVERALL" != "none" ]]; then
    echo "Stopping and removing containers..."
    _compose down
    echo ""
  fi
  echo "Creating and starting containers..."
  _fresh_up
}

# ---- Dispatch

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  echo "Usage: .Makefile.sh <command>" >&2
  echo "Run 'make help' for the full list." >&2
  exit 2
fi
shift

case "$cmd" in
gen-identity) cmd_gen_identity ;;
infos) cmd_infos ;;
build) cmd_build ;;
start) cmd_start ;;
stop) cmd_stop ;;
restart) cmd_restart ;;
logs-gnoland) cmd_logs_gnoland ;;
logs-gnokms) cmd_logs_gnokms ;;
logs-sentinel) cmd_logs_sentinel ;;
status) cmd_status ;;
reset) cmd_reset ;;
clean-imgs) cmd_clean_imgs ;;
update) cmd_update ;;
*)
  echo "Error: unknown command '${cmd}'." >&2
  echo "Run 'make help' for usage." >&2
  exit 2
  ;;
esac
