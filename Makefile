# Makefile — gno-validator: gnoland validator node with gnokms remote signing.
#
# Usage: make <target> [args]
#
# Targets:
#   gen-identity             Generate the validator signing identity in the gnokms keystore
#   infos                    Print node identity, network config, build metadata, and SHA-256 checksums
#   build                    Build Docker images (uses cache; rebuilds automatically when a new commit is available on the target branch)
#   up                       Start all services
#   down                     Stop and remove containers
#   restart                  Stop and start all services (re-reads compose file and applies config changes)
#   logs-gnoland  [SINCE=<d>] Open interactive log TUI — downloads lnav on first run (default history: 1h)
#   logs-gnokms              Follow gnokms logs
#   logs-telemetry           Follow logs for all telemetry services
#   status                   Show container status
#   reset                    Reset node state: remove db and wal, reset priv_validator_state.json
#   update                   Rebuild images and restart (binary update)
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

# All operational logic lives in .Makefile.sh for readability and reuse.
# The Makefile is a thin dispatcher around it.
PROJECT_ROOT := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
SCRIPT       := bash $(PROJECT_ROOT)/.Makefile.sh

.PHONY: help gen-identity infos build up down restart \
        logs-gnoland logs-gnokms logs-telemetry status reset update

help:
	@awk '/^# Usage:/,/^$$/{sub(/^# ?/,""); print}' $(MAKEFILE_LIST)

gen-identity:
	@$(SCRIPT) gen-identity

infos:
	@$(SCRIPT) infos

build:
	@$(SCRIPT) build

up:
	@$(SCRIPT) up

down:
	@$(SCRIPT) down

restart:
	@$(SCRIPT) restart

logs-gnoland:
	@$(SCRIPT) logs-gnoland

logs-gnokms:
	@$(SCRIPT) logs-gnokms

logs-telemetry:
	@$(SCRIPT) logs-telemetry

status:
	@$(SCRIPT) status

reset:
	@$(SCRIPT) reset

update:
	@$(SCRIPT) update
