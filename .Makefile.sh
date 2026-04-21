#!/usr/bin/env bash
# .Makefile.sh — shell backend for the gno-validator Makefile.
#
# Holds every operational command (build, start, stop, gen-identity, ...) so the
# Makefile stays a thin dispatcher. Normally invoked as `make <target>`; can
# also be run directly with `bash .Makefile.sh <command>` from the repo root.
#
# Usage: .Makefile.sh <command>
# Commands: gen-identity, infos, build, start, stop, restart, logs-gnoland,
#           logs-gnokms, logs-telemetry, status, reset, update

set -euo pipefail

# ---- Globals

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

ENV_FILE="validator.env"
STATE_FILE=".build-state"
OVERRIDES_FILE="config.overrides"
GENESIS_FILE="genesis.json"

GNOKMS_IMAGE="gno-validator-gnokms"
GNOLAND_IMAGE="gno-validator-gnoland"
GNOKMS_DATA="gnokms-data"
GNOLAND_DATA="gnoland-data"
GNOKMS_KEYNAME="gnokms-docker-key"

LNAV_VERSION="0.13.2"
JQ_VERSION="1.7.1"
TOOLS_BIN_DIR=".tools/bin"
LNAV_BIN="${TOOLS_BIN_DIR}/lnav"
JQ_BIN="${TOOLS_BIN_DIR}/jq"

# Host UID/GID are consumed by docker-compose.yml for gnoland's user mapping
# (keeps files under gnoland-data/ owned by the operator, not root).
export HOST_UID="${HOST_UID:-$(id -u)}"
export HOST_GID="${HOST_GID:-$(id -g)}"

# ---- validator.env helpers

# Print the raw value of KEY from validator.env (preserves whitespace, empty if unset).
env_get_raw() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
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
  [[ -f "$ENV_FILE" ]] && grep -qE "^$1=.+" "$ENV_FILE" 2>/dev/null
}

# True if validator.env has a line starting with `KEY=VALUE`.
env_matches() {
  [[ -f "$ENV_FILE" ]] && grep -qE "^$1=$2" "$ENV_FILE" 2>/dev/null
}

# Prompt silently for VAR if not set in the environment and not present in validator.env.
# On success, exports VAR so child processes (_compose) pick it up.
prompt_password_if_unset() {
  local var="$1"
  # ${!var:-} = value of $<var>, empty if unset (needed under `set -u`).
  if [[ -z "${!var:-}" ]] && ! env_has_value "$var"; then
    local value
    read -r -s -p "${var}: " value
    echo ""
    export "$var=$value"
  fi
}

# ---- Docker helpers

# Build SERVICE's image with `_compose` if IMAGE is missing locally.
# Used by commands that invoke the image directly (outside _compose).
ensure_image() {
  local image="$1" service="$2"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Building ${service} image, please wait..."
    _compose build "$service"
  fi
}

# Run `_compose` with our env file. Wrapping every call means compose
# sees the same variable interpolation whether invoked via make, directly, or
# from inside the script. Process env still wins over the file (standard
# compose precedence), so prompted passwords override file defaults.
_compose() {
  docker compose --env-file "$ENV_FILE" "$@"
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

# Print SHA-256 of a file inside a Docker image.
sha256_in_image() {
  docker run --rm --entrypoint sha256sum "$1" "$2" | awk '{print $1}'
}

# Print SHA-256 of a local file (portable across Linux and macOS).
sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ---- Image tag + content-hash helpers

# Compute an 8-character content hash from the concatenated content of all
# given files. Deterministic under fixed input order (callers always pass the
# same files in the same order per image target).
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

# Compute the content hash for a given image kind ('gnokms' or 'gnoland').
# Each image hashes its Dockerfile + its own entrypoint, so an edit to one
# entrypoint does not force a rebuild of the other image.
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

# Compute the full content-addressable image tag for an image kind:
#   <gno_commit_12>-<content_hash_8>
# Callers must pass the resolved 40-char commit hash as $2 so the prefix is
# stable regardless of how many chars are in GNO_COMMIT_HASH.
image_tag_for() {
  local kind="$1" commit="$2"
  local content
  content="$(content_hash_for "$kind")"
  printf '%s-%s\n' "${commit:0:12}" "$content"
}

# ---- Build state

# Atomically write the current build state to STATE_FILE. Builds the content
# in a sibling tempfile and renames — so a killed process leaves either the
# old state or no change, never a truncated file.
# Expects in env: GNO_REPO, GNO_VERSION, GNO_COMMIT_HASH.
write_build_state() {
  local out_file="$STATE_FILE"
  local build_date gnokms_content gnoland_content gnokms_image gnoland_image
  build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gnokms_content="$(content_hash_for gnokms)"
  gnoland_content="$(content_hash_for gnoland)"
  gnokms_image="${GNOKMS_IMAGE}:$(image_tag_for gnokms "$GNO_COMMIT_HASH")"
  gnoland_image="${GNOLAND_IMAGE}:$(image_tag_for gnoland "$GNO_COMMIT_HASH")"

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
  } >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$out_file" || {
    rm -f "$tmp"
    return 1
  }
}

# Source STATE_FILE in a subshell and emit bash assignments that populate
# PREV_* variables in the caller's scope. Use as:
#   eval "$(read_build_state_as_prev)"
# Returns non-zero if STATE_FILE is missing, so callers can branch.
read_build_state_as_prev() {
  [[ -f "$STATE_FILE" ]] || return 1
  (
    set +u
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    printf 'PREV_BUILD_DATE=%q\n' "${BUILD_DATE:-}"
    printf 'PREV_GNO_REPO=%q\n' "${GNO_REPO:-}"
    printf 'PREV_GNO_VERSION=%q\n' "${GNO_VERSION:-}"
    printf 'PREV_GNO_COMMIT=%q\n' "${GNO_COMMIT:-}"
    printf 'PREV_GNOKMS_CONTENT_HASH=%q\n' "${GNOKMS_CONTENT_HASH:-}"
    printf 'PREV_GNOLAND_CONTENT_HASH=%q\n' "${GNOLAND_CONTENT_HASH:-}"
    printf 'PREV_GNOKMS_IMAGE_TAG=%q\n' "${GNOKMS_IMAGE_TAG:-}"
    printf 'PREV_GNOLAND_IMAGE_TAG=%q\n' "${GNOLAND_IMAGE_TAG:-}"
  )
}

# Compare PREV_* vars (loaded by read_build_state_as_prev) against the current
# env + filesystem state. Prints a human-readable drift summary to stdout.
# Returns 0 if no drift, 1 if drift detected.
# Expects in env: GNO_REPO, GNO_VERSION, GNO_COMMIT_HASH (and PREV_* set).
build_state_drift_summary() {
  local drift=0

  if [[ "${PREV_GNO_REPO:-}" != "${GNO_REPO:-}" ]]; then
    echo "  gno repo changed: ${PREV_GNO_REPO:-<none>} → ${GNO_REPO:-<none>}"
    drift=1
  elif [[ "${PREV_GNO_VERSION:-}" != "${GNO_VERSION:-}" ]]; then
    echo "  gno ref changed: ${PREV_GNO_VERSION:-<none>} → ${GNO_VERSION:-<none>}"
    drift=1
  elif [[ "${PREV_GNO_COMMIT:-}" != "${GNO_COMMIT_HASH:-}" ]]; then
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

# ---- Drift helpers

# Print a file's mtime as epoch seconds. Handles GNU (stat -c) and BSD (stat -f).
# Prints 0 if the file is missing (so callers treat it as "always newer").
mtime_epoch() {
  [[ -e "$1" ]] || {
    echo 0
    return
  }
  if stat --version >/dev/null 2>&1; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

# Convert a Docker ISO-8601 timestamp ('2026-04-14T14:39:21.555Z' or with offset)
# to epoch seconds. Prints 0 if parsing fails (safer default: treat as 'very old').
iso_to_epoch() {
  local iso="$1"
  [[ -n "$iso" ]] || {
    echo 0
    return
  }
  # Strip fractional seconds and offset/zulu for BSD date compatibility.
  local normalized="${iso%%.*}"
  normalized="${normalized%%+*}"
  normalized="${normalized%Z}"
  if date --version >/dev/null 2>&1; then
    date -u -d "${normalized}Z" +%s 2>/dev/null || echo 0
  else
    date -u -j -f "%Y-%m-%dT%H:%M:%S" "$normalized" +%s 2>/dev/null || echo 0
  fi
}

# Print the epoch time (seconds) of a Docker format path, e.g. `.Created` on the image.
# Args: <image-or-container> <go-template-path>. Prints 0 on failure.
docker_time_epoch() {
  local ref="$1" path="$2" iso
  iso="$(docker inspect --format "{{${path}}}" "$ref" 2>/dev/null || true)"
  iso_to_epoch "$iso"
}

# True if FILE has been modified after the given docker time.
# Args: <file> <docker-ref> <go-template-path>
file_newer_than_docker() {
  local file="$1" ref="$2" path="$3"
  local file_mtime docker_mtime
  file_mtime="$(mtime_epoch "$file")"
  docker_mtime="$(docker_time_epoch "$ref" "$path")"
  ((file_mtime > docker_mtime))
}

# ---- Tool installers

# Download a URL to a file path using curl or wget.
# Returns non-zero if neither is available or the download fails.
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

# Fetch the pinned lnav release into $LNAV_BIN if missing. Returns non-zero if
# the host is missing curl/wget/unzip or runs on an unsupported architecture,
# so callers can fall back to plain logs.
install_lnav() {
  [[ -x "$LNAV_BIN" ]] && return 0

  # Fail fast on platform/tool problems before creating any temp state.
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
  # Manual cleanup on every exit path: avoids the bash 3.2 RETURN-trap-leak
  # pitfall (traps declared in a function persist at shell scope).
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

# Fetch the pinned jq release into $JQ_BIN if missing. Returns non-zero on
# unsupported platform or download failure; callers should degrade gracefully.
# Downloads atomically (tmpfile + mv) so a failed download never leaves a
# partial or half-executable binary behind.
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
  local tmp="${JQ_BIN}.tmp.$$"
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

# Resolve a usable jq binary. Prefer .tools/bin/jq, then system jq, then try
# to install into .tools/bin/jq. Prints the binary path on success; returns
# non-zero on complete failure. Uses printf so exotic paths don't confuse
# callers that capture stdout via $(ensure_jq).
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
# and by cmd_update after cmd_stop. Prompts for passwords if needed, validates
# gnokms keystore, then runs `_compose up -d`.
_fresh_up() {
  [[ -f "$ENV_FILE" ]] || {
    echo "Error: $ENV_FILE not found. Run: cp validator.env.example $ENV_FILE" >&2
    exit 1
  }

  prompt_password_if_unset GNOKMS_PASSWORD
  if env_has_value GRAFANA_ADMIN_USER; then
    prompt_password_if_unset GRAFANA_ADMIN_PASSWORD
  fi
  if env_matches GRAFANA_SMTP_ENABLED true; then
    prompt_password_if_unset GRAFANA_SMTP_PASSWORD
  fi

  # Validate the keystore/password up front: a wrong password would only
  # surface later as a gnokms crash loop, which is much harder to diagnose.
  _compose run --rm --no-deps -T gnokms check >/dev/null
  _compose up -d

  cat <<'EOF'

Started. The gnoland entrypoint regenerates config on every start:
  1. resets gnoland-data/config/config.toml to defaults
  2. applies user-defined overrides from ./config.overrides
  3. applies hardcoded overrides (p2p.laddr, rpc.laddr, remote signer, telemetry)
EOF
}

# Print a drift report comparing current filesystem state against the running
# gnoland container and the images. Exits silently if no containers exist yet.
drift_report() {
  # Print a drift report comparing current filesystem state against the last
  # .build-state snapshot and the running gnoland container. Returns silently
  # if there's nothing to say. Does NOT hit docker unless a container exists.

  # Resolve the current commit so build_state_drift_summary has something to
  # compare to. Offline callers get an empty commit and only content drift
  # is reported (still useful).
  local repo version commit
  repo="$(env_get GNO_REPO gnolang/gno)"
  version="$(env_get GNO_VERSION master)"
  commit="$(git ls-remote "https://github.com/${repo}.git" "$version" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  export GNO_REPO="$repo" GNO_VERSION="$version" GNO_COMMIT_HASH="$commit"

  # Build-state drift (covers commit/version/repo + content hashes).
  # Capture read_build_state_as_prev's exit status via the assignment — if the
  # state file is missing, the assignment itself returns non-zero and the `if`
  # is skipped. Using `if eval "$(...)"; then` would always succeed (eval "" is
  # 0) and we'd mis-report drift on a missing state file.
  local prev_state summary has_drift=0
  if prev_state="$(read_build_state_as_prev 2>/dev/null)"; then
    eval "$prev_state"
    summary="$(build_state_drift_summary)" || has_drift=$?
    if ((has_drift == 1)); then
      echo "Drift detected since last build (${PREV_BUILD_DATE:-unknown}):"
      echo "$summary"
      echo ""
      echo "  Run 'make update' to rebuild and restart."
      echo ""
    fi
  fi

  # config.overrides re-applies on every container start — informational only.
  if docker container inspect gno-validator-gnoland-1 >/dev/null 2>&1; then
    if [[ -f "$OVERRIDES_FILE" ]] &&
      file_newer_than_docker "$OVERRIDES_FILE" gno-validator-gnoland-1 .State.StartedAt; then
      echo "Info: ${OVERRIDES_FILE} modified since last container start — will be re-applied this start."
      echo ""
    fi
  fi
}

# ---- Commands

cmd_gen_identity() {
  ensure_image "$GNOKMS_IMAGE" gnokms
  mkdir -p "${GNOKMS_DATA}/keystore"

  local password="${GNOKMS_PASSWORD:-}"
  [[ -z "$password" ]] && password="$(env_get_raw GNOKMS_PASSWORD)"
  if [[ -z "$password" ]]; then
    read -r -s -p "GNOKMS_PASSWORD: " password
    echo ""
  fi

  # gnokey prompts twice for confirmation — feed the password on both lines.
  printf '%s\n%s\n' "$password" "$password" |
    docker run --rm -i \
      --user "${HOST_UID}:${HOST_GID}" \
      --entrypoint gnokey \
      -v "${PROJECT_ROOT}/${GNOKMS_DATA}:/gnokms-data" \
      "$GNOKMS_IMAGE" \
      add "$GNOKMS_KEYNAME" --home /gnokms-data/keystore --insecure-password-stdin
}

cmd_infos() {
  ensure_image "$GNOLAND_IMAGE" gnoland
  ensure_image "$GNOKMS_IMAGE" gnokms
  mkdir -p "${GNOLAND_DATA}/config" "${GNOLAND_DATA}/secrets"

  echo "=== Identity ==="
  # `gnokey list` can briefly fail with a keystore DB lock when gnokms is
  # actively signing. Capture output separately and tolerate the failure so
  # the rest of `infos` still prints — the operator can retry for identity.
  local gnokey_out
  gnokey_out="$(docker run --rm \
    --entrypoint gnokey \
    -v "${PROJECT_ROOT}/${GNOKMS_DATA}:/gnokms-data" \
    "$GNOKMS_IMAGE" \
    list --home /gnokms-data/keystore 2>/dev/null || true)"
  if [[ -n "$gnokey_out" ]]; then
    echo "$gnokey_out" | awk '{
            for (i = 1; i <= NF; i++) {
                if ($i == "addr:") addr = $(i+1)
                if ($i == "pub:") { pub = $(i+1); sub(/,$/, "", pub) }
            }
            print "validator address: " addr "\nvalidator pub_key: " pub
        }'
  else
    echo "validator address: (gnokey list failed — keystore locked by running gnokms; retry shortly)"
    echo "validator pub_key: (gnokey list failed — keystore locked by running gnokms; retry shortly)"
  fi
  echo "node_id:           $(gnoland_run gnoland secrets get node_id.id --raw)"
  echo "moniker:           $(gnoland_run gnoland config get moniker --raw)"
  echo ""

  echo "=== Network Configuration ==="
  echo "seeds:             $(gnoland_run gnoland config get p2p.seeds --raw)"
  echo "persistent peers:  $(gnoland_run gnoland config get p2p.persistent_peers --raw)"
  echo "p2p listener:      tcp://$(env_get GNOLAND_P2P_LADDR 0.0.0.0):$(env_get GNOLAND_P2P_PORT 26656)"
  echo "rpc listener:      tcp://$(env_get GNOLAND_RPC_LADDR 0.0.0.0):$(env_get GNOLAND_RPC_PORT 26657)"
  echo ""

  echo "=== Build Information ==="
  echo "gno commit:        $(image_label "$GNOLAND_IMAGE" gno.commit)"
  echo "gno version:       $(image_label "$GNOLAND_IMAGE" gno.version)"
  echo "gno repo:          $(image_label "$GNOLAND_IMAGE" gno.repo)"
  echo "build date:        $(image_label "$GNOLAND_IMAGE" build.date)"
  echo ""

  echo "=== Binary Checksums (SHA-256) ==="
  echo "gnoland:           $(sha256_in_image "$GNOLAND_IMAGE" /usr/local/bin/gnoland)"
  echo "gnokey:            $(sha256_in_image "$GNOKMS_IMAGE" /usr/local/bin/gnokey)"
  echo "gnokms:            $(sha256_in_image "$GNOKMS_IMAGE" /usr/local/bin/gnokms)"
  echo ""

  echo "=== File Checksums (SHA-256) ==="
  if [[ -f "$GENESIS_FILE" ]]; then
    echo "genesis.json:      $(sha256_of_file "$GENESIS_FILE")"
  else
    echo "genesis.json:      (not found)"
  fi
}

cmd_build() {
  local repo version commit
  repo="$(env_get GNO_REPO gnolang/gno)"
  version="$(env_get GNO_VERSION master)"

  echo "Resolving commit hash for ${version} on ${repo}..."
  commit="$(git ls-remote "https://github.com/${repo}.git" "$version" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  if [[ -z "$commit" ]]; then
    echo "Warning: could not resolve ${version} to a commit hash (no network or direct commit?), cache may be stale"
    commit="$version"
  fi

  # Export the inputs the Dockerfile ARGs and compose-interpolation need.
  # Split assignment + export so command-sub failures aren't masked by the
  # always-zero exit status of the `export` builtin.
  export GNO_REPO="$repo"
  export GNO_VERSION="$version"
  export GNO_COMMIT_HASH="$commit"
  BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  DOCKERFILE_HASH="$(sha256_of_file Dockerfile)"
  export BUILD_DATE DOCKERFILE_HASH

  echo "Build inputs:"
  echo "  repo=${repo}  version=${version}  commit=${commit:0:12}"
  echo "  dockerfile sha256=${DOCKERFILE_HASH:0:12}"
  echo ""

  local force="${FORCE:-0}"
  if [[ "$force" != "1" ]]; then
    # Skip if .build-state matches current inputs AND both content-tagged
    # images exist locally.
    local prev_state prev_ok=0
    # Capture command-sub exit via the assignment; `if eval "$(...)"; then`
    # would always succeed (eval "" returns 0) and we'd try to match PREV_*
    # values that were never loaded.
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

  # Build each service. ENTRYPOINT_HASH is that image's content hash so the
  # LABEL on each image matches its own content. Split assign + export so
  # a failing sha256_of_file isn't masked by `export`'s always-zero exit.
  ENTRYPOINT_HASH="$(sha256_of_file docker/gnokms-entrypoint.sh)"
  export ENTRYPOINT_HASH
  echo "==> Building gnokms image..."
  _compose build gnokms

  ENTRYPOINT_HASH="$(sha256_of_file docker/gnoland-entrypoint.sh)"
  export ENTRYPOINT_HASH
  echo "==> Building gnoland image..."
  _compose build gnoland

  # Tag both images with content-addressable tags so the operator can roll
  # back to a specific build by retagging it as :latest.
  local gnokms_tag gnoland_tag
  gnokms_tag="$(image_tag_for gnokms "$commit")"
  gnoland_tag="$(image_tag_for gnoland "$commit")"
  docker tag "$GNOKMS_IMAGE" "${GNOKMS_IMAGE}:${gnokms_tag}"
  docker tag "$GNOLAND_IMAGE" "${GNOLAND_IMAGE}:${gnoland_tag}"
  echo ""
  echo "Tagged:"
  echo "  ${GNOKMS_IMAGE}:${gnokms_tag}"
  echo "  ${GNOLAND_IMAGE}:${gnoland_tag}"

  # Snapshot to .build-state so start/update can detect drift without docker.
  write_build_state
  echo ""
  echo "Wrote ${STATE_FILE}."
}

cmd_start() {
  # If the gnoland container has never been created, treat this as first-run:
  # ensure images exist, then _fresh_up. Keeps `make start` the only command
  # an operator needs on a fresh checkout.
  if ! docker container inspect gno-validator-gnoland-1 >/dev/null 2>&1; then
    echo "First run: no gnoland container found. Ensuring images..."
    cmd_build
    echo ""
    echo "Creating and starting containers..."
    _fresh_up
    return
  fi

  # Running → nothing to do (except surface drift).
  if _compose ps --status running -q gnoland 2>/dev/null | grep -q .; then
    echo "Containers already running."
    drift_report
    return
  fi

  drift_report
  echo "Starting containers (config will be regenerated from config.overrides)..."
  _compose start
}

cmd_stop() {
  _compose stop
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_logs_gnoland() {
  local since="${SINCE:-1h}"
  if install_lnav; then
    TERM=xterm-256color "$LNAV_BIN" -I ./.lnav \
      <(_compose logs --since "$since" -f gnoland 2>/dev/null)
  else
    echo "lnav unavailable, falling back to plain logs..."
    _compose logs --since "$since" -f gnoland
  fi
}

cmd_logs_gnokms() {
  _compose logs -f gnokms
}

cmd_logs_telemetry() {
  _compose logs -f otelcol tempo prometheus grafana
}

cmd_status() {
  local watch_interval="${WATCH:-}"
  local rpc_port
  rpc_port="$(env_get GNOLAND_RPC_PORT 26657)"

  # Without jq we can't parse RPC JSON — offer a raw-JSON dump degrade path.
  # Let install_jq's diagnostics surface to the user (download progress, error
  # detail). Only the install path writes to stderr; the Warning below is a
  # one-line summary for the operator.
  local jq_bin
  if ! jq_bin="$(ensure_jq)"; then
    echo "Warning: jq unavailable (auto-install failed). Watch mode disabled; printing raw JSON once." >&2
    _status_raw "$rpc_port"
    return 0
  fi

  if [[ -z "$watch_interval" ]]; then
    _status_render "$rpc_port" "$jq_bin"
    return 0
  fi

  # Validate watch= input before entering the loop so a typo gets a clear
  # error instead of an opaque `sleep: invalid time interval` mid-loop.
  if ! [[ "$watch_interval" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$watch_interval" == "0" ]]; then
    echo "Error: watch= must be a positive number (got '${watch_interval}')." >&2
    return 2
  fi

  # Watch mode — hide cursor, clear screen, loop with ANSI redraw.
  local eol=$'\033[K'
  printf '\033[?25l'
  trap 'printf "\033[?25h\n"' EXIT INT TERM
  printf '\033[2J'
  while true; do
    printf '\033[H'
    printf "Refreshing every %ss (Ctrl+C to stop)${eol}\n\n" "$watch_interval"
    _status_render "$rpc_port" "$jq_bin" "$eol"
    sleep "$watch_interval"
  done
}

# Render a one-row status table. `eol` is optional; in watch mode, pass
# $'\033[K' so shorter values don't leave stale characters.
_status_render() {
  local port="$1" jq="$2" eol="${3:-}"
  local moniker status_json net_json height block peers catching_up vp status validator

  status_json="$(_http_get "http://localhost:${port}/status" || true)"
  net_json="$(_http_get "http://localhost:${port}/net_info" || true)"

  printf "%-16s %-10s %-8s %-24s %-7s %s${eol}\n" "Node" "Status" "Height" "Latest Block" "Peers" "Validator"
  printf "%-16s %-10s %-8s %-24s %-7s %s${eol}\n" "----" "------" "------" "------------" "-----" "---------"

  if [[ -z "$status_json" ]]; then
    printf "%-16s %-10s %-8s %-24s %-7s %s${eol}\n" "-" "unreachable" "-" "-" "-" "-"
    return
  fi

  moniker="$(echo "$status_json" | "$jq" -r '.result.node_info.moniker // "-"' 2>/dev/null || echo "-")"
  height="$(echo "$status_json" | "$jq" -r '.result.sync_info.latest_block_height // "-"' 2>/dev/null || echo "-")"
  block="$(echo "$status_json" | "$jq" -r '(.result.sync_info.latest_block_time // "-")[:19]' 2>/dev/null || echo "-")"
  catching_up="$(echo "$status_json" | "$jq" -r '.result.sync_info.catching_up // false' 2>/dev/null || echo "false")"
  vp="$(echo "$status_json" | "$jq" -r '.result.validator_info.voting_power // "0"' 2>/dev/null || echo "0")"
  peers="$(echo "$net_json" | "$jq" -r '.result.n_peers // "-"' 2>/dev/null || echo "-")"

  if [[ "$catching_up" == "true" ]]; then status="syncing"; else status="running"; fi
  if [[ "$vp" == "0" || -z "$vp" ]]; then validator="no"; else validator="yes (VP ${vp})"; fi

  printf "%-16s %-10s %-8s %-24s %-7s %s${eol}\n" "$moniker" "$status" "$height" "$block" "$peers" "$validator"
}

# Degraded fallback: dump raw JSON from /status and /net_info (no parsing).
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

# HTTP GET with curl→wget fallback. 2s timeout. Returns non-zero on failure.
_http_get() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 2 "$url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=2 "$url" 2>/dev/null
  else
    return 1
  fi
}

cmd_reset() {
  # Figure out current state of the gnoland container.
  local was_running=0
  if docker container inspect gno-validator-gnoland-1 >/dev/null 2>&1 &&
    _compose ps --status running -q gnoland 2>/dev/null | grep -q .; then
    was_running=1
  fi

  echo "About to reset chain state."
  echo "  Will delete: ${GNOLAND_DATA}/db, ${GNOLAND_DATA}/wal"
  echo "  Will reset : ${GNOLAND_DATA}/secrets/priv_validator_state.json"
  echo "  Will keep  : keystore (${GNOKMS_DATA}/), validator keys, node_id, config, grafana data"

  local confirm
  read -r -p "Continue? [y/N] " confirm
  [[ "$confirm" == "y" || "$confirm" == "Y" ]] || {
    echo "Aborted."
    exit 1
  }

  if ((was_running == 1)); then
    read -r -p "Containers are running — stop them first? [Y/n] " confirm
    if [[ "$confirm" != "n" && "$confirm" != "N" ]]; then
      cmd_stop
    else
      echo "Warning: resetting while containers run may corrupt data. Proceeding anyway."
    fi
  fi

  echo "Resetting..."
  rm -rf "${GNOLAND_DATA}/db" "${GNOLAND_DATA}/wal"
  printf '{\n  "height": "0",\n  "round": "0",\n  "step": 0\n}\n' \
    >"${GNOLAND_DATA}/secrets/priv_validator_state.json"
  echo "Reset complete."

  if ((was_running == 1)); then
    read -r -p "Start containers again? [Y/n] " confirm
    if [[ "$confirm" != "n" && "$confirm" != "N" ]]; then
      cmd_start
    fi
  fi
}

cmd_clean_imgs() {
  local skip_prompt="${YES:-0}"
  # Collect all tags for our two repositories. `docker images` accepts only
  # one [REPOSITORY[:TAG]] arg at a time, so we invoke it twice and merge.
  local -a images=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && images+=("$line")
  done < <({
    docker images --format '{{.Repository}}:{{.Tag}}' "$GNOKMS_IMAGE"
    docker images --format '{{.Repository}}:{{.Tag}}' "$GNOLAND_IMAGE"
  } | sort -u)

  if ((${#images[@]} == 0)); then
    echo "No gno-validator images to remove."
    return 0
  fi

  echo "Will remove the following images:"
  local i
  for i in "${images[@]:-}"; do
    echo "  - $i"
  done
  echo ""
  echo "Note: containers using these images must be stopped first."
  echo ""

  if ((skip_prompt != 1)); then
    local confirm
    read -r -p "Continue? [y/N] " confirm || true
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      echo "Aborted."
      exit 1
    fi
  fi

  docker rmi -f -- "${images[@]}"
  echo "Removed ${#images[@]} image(s)."
}

cmd_update() {
  local force="${FORCE:-0}"
  local cname="gno-validator-gnoland-1"

  # Resolve current commit for drift comparison.
  local repo version commit
  repo="$(env_get GNO_REPO gnolang/gno)"
  version="$(env_get GNO_VERSION master)"
  commit="$(git ls-remote "https://github.com/${repo}.git" "$version" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  export GNO_REPO="$repo" GNO_VERSION="$version" GNO_COMMIT_HASH="${commit:-$version}"

  # Decide what's needed.
  local need_rebuild=0 need_recreate=0
  local -a reasons=()

  # Build-state drift → rebuild. Capture the command-sub exit status via the
  # assignment so a missing state file correctly reports "state missing".
  local prev_state
  if prev_state="$(read_build_state_as_prev 2>/dev/null)"; then
    # eval of printf '%q'-quoted PREV_* assignments — safe by construction.
    eval "$prev_state"
    # build_state_drift_summary returns 1 when drift IS detected. Capture the
    # exit via `|| has_drift=$?` (plain call would trip set -e on drift).
    local summary has_drift=0
    summary="$(build_state_drift_summary)" || has_drift=$?
    if ((has_drift == 1)); then
      need_rebuild=1
      reasons+=("build inputs changed since last build:")
      while IFS= read -r line; do
        reasons+=("  ${line}")
      done <<<"$summary"
    fi
  else
    need_rebuild=1
    reasons+=(".build-state missing — no record of last build")
  fi

  # Runtime drift → recreate (compose.yml / validator.env edited after container created).
  if docker container inspect "$cname" >/dev/null 2>&1; then
    if file_newer_than_docker "$ENV_FILE" "$cname" .Created; then
      need_recreate=1
      reasons+=("${ENV_FILE} modified since containers were created")
    fi
    if file_newer_than_docker docker-compose.yml "$cname" .Created; then
      need_recreate=1
      reasons+=("docker-compose.yml modified since containers were created")
    fi
  else
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
    if docker container inspect "$cname" >/dev/null 2>&1; then
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
  echo "           genesis.json, and named volumes (grafana_data, gnokms-sock)."
  echo ""

  if ((force == 0)); then
    local confirm=""
    # `|| true` so an EOF/non-TTY stdin doesn't trip set -e (non-interactive
    # callers should pass force=1 explicitly; default-yes on empty is safe).
    read -r -p "Continue? [Y/n] " confirm || true
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
      echo "Aborted."
      exit 1
    fi
  fi

  if ((need_rebuild == 1)); then
    cmd_build
    echo ""
  fi
  if docker container inspect "$cname" >/dev/null 2>&1; then
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
logs-telemetry) cmd_logs_telemetry ;;
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
