# Makefile — gno-validator: gnoland validator node with gnokms remote signing.
#
# Usage: make <target> [args]
#
# Lifecycle:
#   start                    Start services (first run: builds images if needed,
#                            generates config, and creates containers)
#   stop                     Stop services without removing containers
#   restart                  Stop then start (re-applies config.overrides, no password prompt)
#   update   [force=1]       Rebuild images and/or recreate containers if anything
#                            has changed since the last build/start. force=1 does it anyway.
#                            Recreate loses container logs but preserves chain data + keystore.
#   reset                    Wipe chain state (db, wal, priv_validator_state.json) with
#                            interactive prompts to stop/start containers around the reset.
#
# Inspection:
#   status   [watch=<sec>]   Show block height, peers, and validator status (watch= refreshes every N seconds)
#   infos                    Print node identity, network config, build metadata, checksums
#   logs-gnoland  [SINCE=<d>] Open interactive log TUI — downloads lnav on first run (default: 1h)
#   logs-gnokms              Follow gnokms logs
#   logs-telemetry           Follow logs for all telemetry services
#
# Cleanup:
#   clean-imgs  [yes=1]      Remove all gno-validator Docker images (yes=1 skips the prompt)
#
# Setup / build:
#   gen-identity             Generate the validator signing identity in the gnokms keystore
#   build    [force=1]       Build missing images; skip when .build-state matches current inputs.
#                            Normally automatic via start/update; run manually for CI or debugging.
#   help                     Show this help message
#
# Configuration:
#   validator.env            Environment variables (copy from validator.env.example)
#   config.overrides         Per-node gnoland config (copy from config.overrides.example)
#   genesis.json             Chain genesis file (user-provided)

SHELL := /bin/bash

# HOST_UID/HOST_GID are consumed by docker-compose.yml for gnoland's user mapping.
export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)

# Arg → env pass-through: `make build force=1` → FORCE=1, `make status watch=5` → WATCH=5,
# `make clean-imgs yes=1` → YES=1.
export FORCE := $(force)
export WATCH := $(watch)
export YES   := $(yes)

PROJECT_ROOT := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
SCRIPT       := bash $(PROJECT_ROOT)/.Makefile.sh

.PHONY: help gen-identity infos build start stop restart update reset \
        logs-gnoland logs-gnokms logs-telemetry status clean-imgs

help:
	@awk '/^# Usage:/,/^$$/{sub(/^# ?/,""); print}' $(MAKEFILE_LIST)

gen-identity:
	@$(SCRIPT) gen-identity

infos:
	@$(SCRIPT) infos

build:
	@$(SCRIPT) build

start:
	@$(SCRIPT) start

stop:
	@$(SCRIPT) stop

restart:
	@$(SCRIPT) restart

update:
	@$(SCRIPT) update

reset:
	@$(SCRIPT) reset

logs-gnoland:
	@$(SCRIPT) logs-gnoland

logs-gnokms:
	@$(SCRIPT) logs-gnokms

logs-telemetry:
	@$(SCRIPT) logs-telemetry

status:
	@$(SCRIPT) status

clean-imgs:
	@$(SCRIPT) clean-imgs
