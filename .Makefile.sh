#!/usr/bin/env bash
# .Makefile.sh — shell backend for the gno-validator Makefile.
#
# Holds every operational command (build, up, down, gen-identity, ...) so the
# Makefile stays a thin dispatcher. Normally invoked as `make <target>`; can
# also be run directly with `bash .Makefile.sh <command>` from the repo root.
#
# Usage: .Makefile.sh <command>
# Commands: gen-identity, infos, build, up, down, restart, logs-gnoland,
#           logs-gnokms, logs-telemetry, status, reset, update

set -euo pipefail

# ---- Globals

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

ENV_FILE=".env"
OVERRIDES_FILE="config.overrides"
GENESIS_FILE="genesis.json"

GNOKMS_IMAGE="gno-validator-gnokms"
GNOLAND_IMAGE="gno-validator-gnoland"
GNOKMS_DATA="gnokms-data"
GNOLAND_DATA="gnoland-data"
GNOKMS_KEYNAME="gnokms-docker-key"

LNAV_VERSION="0.13.2"
LNAV_BIN=".lnav/bin/lnav"

# Host UID/GID are consumed by docker-compose.yml for gnoland's user mapping
# (keeps files under gnoland-data/ owned by the operator, not root).
export HOST_UID="${HOST_UID:-$(id -u)}"
export HOST_GID="${HOST_GID:-$(id -g)}"

# ---- .env helpers

# Print the raw value of KEY from .env (preserves whitespace, empty if unset).
env_get_raw() {
    [[ -f "$ENV_FILE" ]] || return 0
    grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Print KEY from .env with all whitespace stripped and a default fallback.
# Use for config values (ports, IPs, repo slugs); use env_get_raw for secrets
# where a legitimate space must be preserved.
env_get() {
    local value
    value="$(env_get_raw "$1")"
    value="${value//[[:space:]]/}"
    printf '%s\n' "${value:-${2:-}}"
}

# True if .env has `KEY=<non-empty>`.
env_has_value() {
    [[ -f "$ENV_FILE" ]] && grep -qE "^$1=.+" "$ENV_FILE" 2>/dev/null
}

# True if .env has a line starting with `KEY=VALUE`.
env_matches() {
    [[ -f "$ENV_FILE" ]] && grep -qE "^$1=$2" "$ENV_FILE" 2>/dev/null
}

# Prompt silently for VAR if not set in the environment and not present in .env.
# On success, exports VAR so child processes (docker compose) pick it up.
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

# Build SERVICE's image with `docker compose` if IMAGE is missing locally.
# Used by commands that invoke the image directly (outside docker compose).
ensure_image() {
    local image="$1" service="$2"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo "Building ${service} image, please wait..."
        docker compose build "$service"
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

# ---- lnav installer

# Fetch the pinned lnav release into $LNAV_BIN if missing. Returns non-zero if
# the host is missing curl/wget/unzip or runs on an unsupported architecture,
# so callers can fall back to plain logs.
install_lnav() {
    [[ -x "$LNAV_BIN" ]] && return 0

    rm -rf ".lnav/bin/lnav.zip" ".lnav/bin/lnav-${LNAV_VERSION}"
    mkdir -p .lnav/bin

    local fetch
    if command -v curl >/dev/null 2>&1; then
        fetch=(curl -fsSL -o)
    elif command -v wget >/dev/null 2>&1; then
        fetch=(wget -q -O)
    else
        echo "Error: curl or wget is required to download lnav" >&2
        return 1
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        echo "Error: unzip is required to extract lnav" >&2
        return 1
    fi

    local os arch zip
    os="$(uname -s)"
    arch="$(uname -m)"
    case "${os}/${arch}" in
        Darwin/arm64)  zip="lnav-${LNAV_VERSION}-aarch64-macos.zip" ;;
        Darwin/*)      zip="lnav-${LNAV_VERSION}-x86_64-macos.zip" ;;
        Linux/aarch64) zip="lnav-${LNAV_VERSION}-linux-musl-arm64.zip" ;;
        Linux/*)       zip="lnav-${LNAV_VERSION}-linux-musl-x86_64.zip" ;;
        *)
            echo "Error: unsupported platform ${os}/${arch}" >&2
            return 1
            ;;
    esac

    echo "Downloading lnav v${LNAV_VERSION}..."
    "${fetch[@]}" ".lnav/bin/lnav.zip" \
        "https://github.com/tstack/lnav/releases/download/v${LNAV_VERSION}/${zip}"
    unzip -q ".lnav/bin/lnav.zip" "lnav-${LNAV_VERSION}/lnav" -d .lnav/bin
    mv ".lnav/bin/lnav-${LNAV_VERSION}/lnav" "$LNAV_BIN"
    rm -rf ".lnav/bin/lnav.zip" ".lnav/bin/lnav-${LNAV_VERSION}"
    chmod +x "$LNAV_BIN"
    echo "lnav installed at ${LNAV_BIN}"
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
    printf '%s\n%s\n' "$password" "$password" \
        | docker run --rm -i \
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
    docker run --rm \
        --entrypoint gnokey \
        -v "${PROJECT_ROOT}/${GNOKMS_DATA}:/gnokms-data" \
        "$GNOKMS_IMAGE" \
        list --home /gnokms-data/keystore \
    | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "addr:") addr = $(i+1)
            if ($i == "pub:") { pub = $(i+1); sub(/,$/, "", pub) }
        }
        print "validator address: " addr "\nvalidator pub_key: " pub
    }'
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
    # Pin the build to an immutable commit so Docker's layer cache keys off the
    # commit hash and not the branch ref (branches are cache-unfriendly because
    # they move but the cache can't tell).
    commit="$(git ls-remote "https://github.com/${repo}.git" "$version" 2>/dev/null | awk '{print $1}' | head -1)"
    if [[ -z "$commit" ]]; then
        echo "Warning: could not resolve ${version} to a commit hash (no network or direct commit?), cache may be stale"
        commit="$version"
    fi
    echo "Building gno@${commit:0:12} (${version} on ${repo})"

    export GNO_COMMIT_HASH="$commit"
    export BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    docker compose build
}

cmd_up() {
    [[ -f "$ENV_FILE" ]] || {
        echo "Error: .env not found. Run: cp .env.example .env" >&2
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
    docker compose run --rm --no-deps -T gnokms check >/dev/null
    docker compose up -d
}

cmd_down() {
    docker compose down
}

cmd_restart() {
    cmd_down
    cmd_up
}

cmd_logs_gnoland() {
    local since="${SINCE:-1h}"
    if install_lnav; then
        TERM=xterm-256color "$LNAV_BIN" -I ./.lnav \
            <(docker compose logs --since "$since" -f gnoland 2>/dev/null)
    else
        echo "lnav unavailable, falling back to plain logs..."
        docker compose logs --since "$since" -f gnoland
    fi
}

cmd_logs_gnokms() {
    docker compose logs -f gnokms
}

cmd_logs_telemetry() {
    docker compose logs -f otelcol tempo prometheus grafana
}

cmd_status() {
    docker compose ps
}

cmd_reset() {
    echo "WARNING: This will erase the node state. Ensure the node is stopped ('make down') first."
    local confirm
    read -r -p "Are you sure? [y/N] " confirm
    [[ "$confirm" == "y" ]] || exit 1

    echo "Resetting ${GNOLAND_DATA}/db, ${GNOLAND_DATA}/wal and ${GNOLAND_DATA}/secrets/priv_validator_state.json"
    rm -rf "${GNOLAND_DATA}/db" "${GNOLAND_DATA}/wal"
    printf '{\n  "height": "0",\n  "round": "0",\n  "step": 0\n}\n' \
        > "${GNOLAND_DATA}/secrets/priv_validator_state.json"
}

cmd_update() {
    cmd_build
    cmd_up
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
    gen-identity)   cmd_gen_identity ;;
    infos)          cmd_infos ;;
    build)          cmd_build ;;
    up)             cmd_up ;;
    down)           cmd_down ;;
    restart)        cmd_restart ;;
    logs-gnoland)   cmd_logs_gnoland ;;
    logs-gnokms)    cmd_logs_gnokms ;;
    logs-telemetry) cmd_logs_telemetry ;;
    status)         cmd_status ;;
    reset)          cmd_reset ;;
    update)         cmd_update ;;
    *)
        echo "Error: unknown command '${cmd}'." >&2
        echo "Run 'make help' for usage." >&2
        exit 2
        ;;
esac
