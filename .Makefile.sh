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

# ---- Build-hash helpers

# Print the build input hash for an image target.
# KIND is 'gnokms' or 'gnoland'; the function knows which entrypoint to hash.
# Output format: "<label>=<value>" lines, so callers can compare with `docker inspect`.
image_input_hashes() {
    local kind="$1"
    local entrypoint
    case "$kind" in
        gnokms)  entrypoint="docker/gnokms-entrypoint.sh" ;;
        gnoland) entrypoint="docker/gnoland-entrypoint.sh" ;;
        *) echo "image_input_hashes: unknown kind '$kind'" >&2; return 1 ;;
    esac
    printf 'build.commit=%s\n' "${GNO_COMMIT_HASH:-}"
    printf 'build.version=%s\n' "${GNO_VERSION:-}"
    printf 'build.repo=%s\n' "${GNO_REPO:-}"
    printf 'build.dockerfile_hash=%s\n' "$(sha256_of_file Dockerfile)"
    printf 'build.entrypoint_hash=%s\n' "$(sha256_of_file "$entrypoint")"
}

# Returns 0 (true) if the image needs to be rebuilt because any non-date build
# input differs from what's labeled on the current image. Prints the specific
# labels that changed to stderr so callers can include them in messages.
image_needs_rebuild() {
    local image="$1" kind="$2"
    # No image at all → must build.
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo "  ${kind}: no image" >&2
        return 0
    fi
    local expected actual key value drift=0
    while IFS='=' read -r key value; do
        actual="$(image_label "$image" "$key")"
        if [[ "$actual" != "$value" ]]; then
            echo "  ${kind}: ${key} differs (image: '${actual:-<unset>}', current: '${value:-<unset>}')" >&2
            drift=1
        fi
    done < <(image_input_hashes "$kind")
    return $((drift == 0))
}

# ---- Drift helpers

# Print a file's mtime as epoch seconds. Handles GNU (stat -c) and BSD (stat -f).
# Prints 0 if the file is missing (so callers treat it as "always newer").
mtime_epoch() {
    [[ -e "$1" ]] || { echo 0; return; }
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
    [[ -n "$iso" ]] || { echo 0; return; }
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
    (( file_mtime > docker_mtime ))
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

# ---- Lifecycle helpers

# Create-and-start the containers from scratch. Used by cmd_start on first run,
# and by cmd_update after cmd_stop. Prompts for passwords if needed, validates
# gnokms keystore, then runs `docker compose up -d`.
_fresh_up() {
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
    # Only makes sense if the gnoland container has been created at least once.
    if ! docker container inspect gno-validator-gnoland-1 >/dev/null 2>&1; then
        return 0
    fi

    local cname="gno-validator-gnoland-1"
    local -a needs_update=() needs_restart=()

    # Build inputs (images): compare to image .Created.
    if [[ -f Dockerfile ]] && file_newer_than_docker Dockerfile "$GNOLAND_IMAGE" .Created; then
        needs_update+=("Dockerfile modified since gnoland image was built")
    fi
    if [[ -f docker/gnoland-entrypoint.sh ]] && file_newer_than_docker docker/gnoland-entrypoint.sh "$GNOLAND_IMAGE" .Created; then
        needs_update+=("docker/gnoland-entrypoint.sh modified since image was built")
    fi
    if [[ -f docker/gnokms-entrypoint.sh ]] && file_newer_than_docker docker/gnokms-entrypoint.sh "$GNOKMS_IMAGE" .Created; then
        needs_update+=("docker/gnokms-entrypoint.sh modified since gnokms image was built")
    fi

    # Runtime inputs: compare to container .Created.
    if file_newer_than_docker "$ENV_FILE" "$cname" .Created; then
        needs_update+=(".env modified since containers were created")
    fi
    if file_newer_than_docker docker-compose.yml "$cname" .Created; then
        needs_update+=("docker-compose.yml modified since containers were created")
    fi

    # config.overrides re-applies on every container start.
    if [[ -f "$OVERRIDES_FILE" ]] && file_newer_than_docker "$OVERRIDES_FILE" "$cname" .State.StartedAt; then
        needs_restart+=("config.overrides modified since last container start — will be re-applied this start")
    fi

    if (( ${#needs_update[@]} > 0 )); then
        echo "Drift detected (requires 'make update' to fully apply):"
        local line
        for line in "${needs_update[@]}"; do
            echo "  - $line"
        done
        echo ""
    fi
    if (( ${#needs_restart[@]} > 0 )); then
        local line
        for line in "${needs_restart[@]}"; do
            echo "Info: $line"
        done
        echo ""
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
    commit="$(git ls-remote "https://github.com/${repo}.git" "$version" 2>/dev/null | awk '{print $1}' | head -1 || true)"
    if [[ -z "$commit" ]]; then
        echo "Warning: could not resolve ${version} to a commit hash (no network or direct commit?), cache may be stale"
        commit="$version"
    fi

    # Export so image_input_hashes, compose, and the Dockerfile ARGs all see the same values.
    export GNO_REPO="$repo"
    export GNO_VERSION="$version"
    export GNO_COMMIT_HASH="$commit"
    export BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export DOCKERFILE_HASH="$(sha256_of_file Dockerfile)"

    # Decide per-image whether a rebuild is needed.
    local force="${FORCE:-0}" gnokms_needs gnoland_needs
    echo "Build inputs:"
    echo "  repo=${repo}  version=${version}  commit=${commit:0:12}"
    echo "  dockerfile sha256=${DOCKERFILE_HASH:0:12}"
    echo ""

    if [[ "$force" == "1" ]]; then
        echo "FORCE=1 → rebuilding both images."
        gnokms_needs=1; gnoland_needs=1
    else
        echo "Comparing with existing image labels..."
        if image_needs_rebuild "$GNOKMS_IMAGE" gnokms; then
            gnokms_needs=1
        else
            gnokms_needs=0
            echo "  gnokms: up to date"
        fi
        if image_needs_rebuild "$GNOLAND_IMAGE" gnoland; then
            gnoland_needs=1
        else
            gnoland_needs=0
            echo "  gnoland: up to date"
        fi
        echo ""
    fi

    if (( gnokms_needs == 0 && gnoland_needs == 0 )); then
        echo "Nothing to rebuild (pass force=1 to rebuild anyway)."
        return 0
    fi

    # Build each image with its own entrypoint-hash label.
    if (( gnokms_needs == 1 )); then
        echo "==> Building gnokms image..."
        export ENTRYPOINT_HASH="$(sha256_of_file docker/gnokms-entrypoint.sh)"
        docker compose build gnokms
    fi
    if (( gnoland_needs == 1 )); then
        echo "==> Building gnoland image..."
        export ENTRYPOINT_HASH="$(sha256_of_file docker/gnoland-entrypoint.sh)"
        docker compose build gnoland
    fi
}

cmd_start() {
    # If the gnoland container has never been created, treat this as first-run:
    # ensure images exist, then _fresh_up. Users shouldn't need a separate
    # `make up` on a fresh checkout.
    if ! docker container inspect gno-validator-gnoland-1 >/dev/null 2>&1; then
        echo "First run: no gnoland container found. Ensuring images..."
        cmd_build
        echo ""
        echo "Creating and starting containers..."
        _fresh_up
        return
    fi

    # Running → nothing to do (except surface drift).
    if docker compose ps --status running -q gnoland 2>/dev/null | grep -q .; then
        echo "Containers already running."
        drift_report
        return
    fi

    drift_report
    echo "Starting containers (config will be regenerated from config.overrides)..."
    docker compose start
}

cmd_stop() {
    docker compose stop
}

cmd_restart() {
    cmd_stop
    cmd_start
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
    # Figure out current state of the gnoland container.
    local was_running=0 exists=1
    if ! docker container inspect gno-validator-gnoland-1 >/dev/null 2>&1; then
        exists=0
    elif docker compose ps --status running -q gnoland 2>/dev/null | grep -q .; then
        was_running=1
    fi

    echo "About to reset chain state."
    echo "  Will delete: ${GNOLAND_DATA}/db, ${GNOLAND_DATA}/wal"
    echo "  Will reset : ${GNOLAND_DATA}/secrets/priv_validator_state.json"
    echo "  Will keep  : keystore (${GNOKMS_DATA}/), validator keys, node_id, config, grafana data"

    local confirm
    read -r -p "Continue? [y/N] " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Aborted."; exit 1; }

    if (( was_running == 1 )); then
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
        > "${GNOLAND_DATA}/secrets/priv_validator_state.json"
    echo "Reset complete."

    if (( was_running == 1 )); then
        read -r -p "Start containers again? [Y/n] " confirm
        if [[ "$confirm" != "n" && "$confirm" != "N" ]]; then
            cmd_start
        fi
    fi
}

cmd_update() {
    local force="${FORCE:-0}"
    local cname="gno-validator-gnoland-1"

    # Decide what needs to happen.
    local need_rebuild=0 need_recreate=0
    local -a reasons=()

    # Determine current commit (same logic as cmd_build).
    local repo version commit
    repo="$(env_get GNO_REPO gnolang/gno)"
    version="$(env_get GNO_VERSION master)"
    commit="$(git ls-remote "https://github.com/${repo}.git" "$version" 2>/dev/null | awk '{print $1}' | head -1 || true)"
    commit="${commit:-$version}"

    # Check image drift (build inputs).
    export GNO_REPO="$repo" GNO_VERSION="$version" GNO_COMMIT_HASH="$commit"
    export DOCKERFILE_HASH="$(sha256_of_file Dockerfile)"
    if image_needs_rebuild "$GNOKMS_IMAGE" gnokms 2>/dev/null; then
        need_rebuild=1
        reasons+=("gnokms image out of date")
    fi
    if image_needs_rebuild "$GNOLAND_IMAGE" gnoland 2>/dev/null; then
        need_rebuild=1
        reasons+=("gnoland image out of date")
    fi

    # Check runtime drift (recreate triggers).
    if docker container inspect "$cname" >/dev/null 2>&1; then
        if file_newer_than_docker "$ENV_FILE" "$cname" .Created; then
            need_recreate=1
            reasons+=(".env modified since containers were created")
        fi
        if file_newer_than_docker docker-compose.yml "$cname" .Created; then
            need_recreate=1
            reasons+=("docker-compose.yml modified since containers were created")
        fi
    else
        # No container yet — recreate implicitly happens via _fresh_up.
        need_recreate=1
        reasons+=("containers not yet created")
    fi

    # If a rebuild is needed we always recreate too (new image → new container).
    (( need_rebuild == 1 )) && need_recreate=1

    if (( need_rebuild == 0 && need_recreate == 0 && force == 0 )); then
        echo "Already up to date (pass force=1 to recreate anyway)."
        return 0
    fi

    if (( force == 1 )); then
        reasons+=("force=1")
    fi

    echo "Update will:"
    (( need_rebuild == 1 )) && echo "  - rebuild images"
    (( need_recreate == 1 )) && echo "  - stop and recreate containers (container logs will be lost)"
    echo ""
    echo "Reasons:"
    local r
    for r in "${reasons[@]}"; do
        echo "  - $r"
    done
    echo ""
    echo "Preserved: ${GNOLAND_DATA}/ (chain db, wal, keys, config), ${GNOKMS_DATA}/ (keystore),"
    echo "           genesis.json, and named volumes (grafana_data, gnokms-sock)."
    echo ""

    if (( force == 0 )); then
        local confirm
        read -r -p "Continue? [Y/n] " confirm
        if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            echo "Aborted."; exit 1
        fi
    fi

    if (( need_rebuild == 1 )); then
        cmd_build
        echo ""
    fi

    if docker container inspect "$cname" >/dev/null 2>&1; then
        echo "Stopping and removing containers..."
        docker compose down
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
    gen-identity)   cmd_gen_identity ;;
    infos)          cmd_infos ;;
    build)          cmd_build ;;
    start)          cmd_start ;;
    stop)           cmd_stop ;;
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
