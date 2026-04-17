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
# Build (usually automatic via start/update; run manually for CI or debugging):
#   build    [force=1]       Build missing images; skip images whose labels match the
#                            current build inputs (commit, Dockerfile, entrypoints).
#
# Inspection:
#   infos                    Print node identity, network config, build metadata, checksums
#   status                   Show container status
#   logs-gnoland  [SINCE=<d>] Open interactive log TUI — downloads lnav on first run (default: 1h)
#   logs-gnokms              Follow gnokms logs
#   logs-telemetry           Follow logs for all telemetry services
#
# Other:
#   gen-identity             Generate the validator signing identity in the gnokms keystore
#   help                     Show this help message
#
# Configuration:
#   .env                     Environment variables (copy from .env.example)
#   config.overrides         Per-node gnoland config (copy from config.overrides.example)
#   genesis.json             Chain genesis file (user-provided)

SHELL := /bin/bash

# HOST_UID/HOST_GID are consumed by docker-compose.yml for gnoland's user mapping.
export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)

# force=1 on the make command line flips FORCE=1 in the script env.
export FORCE := $(force)

PROJECT_ROOT := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
SCRIPT       := bash $(PROJECT_ROOT)/.Makefile.sh

.PHONY: help gen-identity infos build start stop restart update reset \
        logs-gnoland logs-gnokms logs-telemetry status

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
