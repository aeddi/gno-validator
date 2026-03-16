SHELL := /bin/bash

.PHONY: init gen-identity print-identity build up down restart logs logs-gnoland logs-gnokms status update reset .check-env

.check-env:
	@test -f .env || (echo "Error: .env not found. Run: cp .env.example .env" && exit 1)

init: .check-env build ## First-time setup: build images, init node config/secrets
	@mkdir -p gnoland-data/config gnoland-data/secrets gnokms-data/keystore
	docker compose run --rm gnoland gnoland config init \
		-config-path /gnoland-data/config/config.toml
	docker compose run --rm gnoland gnoland secrets init \
		-data-dir /gnoland-data/secrets
	@echo ""
	@echo "Init complete. Before running 'make up':"
	@echo "  1. Edit gnoland-data/config/config.toml — set moniker and p2p.external_address"
	@echo "  2. Copy genesis.json to the repo root"
	@echo ""
	@echo "  Note: consensus remote signer and telemetry settings are applied automatically on"
	@echo "        each start — manual edits to those keys in config.toml will be overwritten."

gen-identity: ## Generate the validator signing identity in the gnokms keystore
	@mkdir -p gnokms-data/keystore
	@if grep -qE '^GNOKMS_PASSWORD=.+' .env 2>/dev/null; then \
		echo "Note: using GNOKMS_PASSWORD from .env (password not shown)"; \
		pass=$$(grep -E '^GNOKMS_PASSWORD=' .env | cut -d= -f2-) && \
		printf '%s\n%s\n' "$$pass" "$$pass" | \
		docker run --rm -i \
			--entrypoint gnokey \
			-v "$(CURDIR)/gnokms-data:/gnokms-data" \
			gno-validator-gnokms \
			add gnokms-docker-key --home /gnokms-data/keystore --insecure-password-stdin; \
	else \
		docker run --rm -it \
			--entrypoint gnokey \
			-v "$(CURDIR)/gnokms-data:/gnokms-data" \
			gno-validator-gnokms \
			add gnokms-docker-key --home /gnokms-data/keystore; \
	fi

print-identity: ## Print the validator identity (address and public key) from the keystore
	@docker run --rm \
		--entrypoint gnokey \
		-v "$(CURDIR)/gnokms-data:/gnokms-data" \
		gno-validator-gnokms \
		list --home /gnokms-data/keystore \
	| awk '{for(i=1;i<=NF;i++){if($$i=="addr:") addr=$$(i+1); if($$i=="pub:"){pub=$$(i+1); sub(/,$$/, "", pub)}} print "address: " addr "\npub_key: " pub}'

build: ## Build Docker images
	docker compose build

up: .check-env ## Start all services
	@if ! grep -qE '^GNOKMS_PASSWORD=.+' .env 2>/dev/null; then \
		read -s -p "GNOKMS_PASSWORD: " pass && echo "" && \
		GNOKMS_PASSWORD="$$pass" docker compose up -d; \
	else \
		docker compose up -d; \
	fi

down: ## Stop and remove containers
	docker compose down

restart: ## Restart all services (does not re-read compose file; use 'make down && make up' after config changes)
	docker compose restart

logs: ## Follow logs for all services
	docker compose logs -f

logs-gnoland: ## Follow gnoland logs
	docker compose logs -f gnoland

logs-gnokms: ## Follow gnokms logs
	docker compose logs -f gnokms

status: ## Show container status
	docker compose ps

reset: ## Reset node state: remove db and wal, reset priv_validator_state.json
	@echo "WARNING: This will erase the node state. Ensure the node is stopped ('make down') first."
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	rm -rf gnoland-data/db gnoland-data/wal
	printf '{\n  "height": "0",\n  "round": "0",\n  "step": 0\n}\n' > gnoland-data/secrets/priv_validator_state.json

update: .check-env build ## Rebuild images and restart (binary update)
	@if ! grep -qE '^GNOKMS_PASSWORD=.+' .env 2>/dev/null; then \
		read -s -p "GNOKMS_PASSWORD: " pass && echo "" && \
		GNOKMS_PASSWORD="$$pass" docker compose up -d; \
	else \
		docker compose up -d; \
	fi
