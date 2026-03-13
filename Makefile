.PHONY: init genesis build up down restart logs logs-gnoland logs-gnokms status update

init: build genesis ## First-time setup: build images, generate genesis, init node config/secrets
	@mkdir -p gnoland-data/config gnoland-data/secrets gnokms-data/keystore
	docker compose run --rm gnoland gnoland config init \
		-config-path /gnoland-data/config/config.toml
	docker compose run --rm gnoland gnoland config set \
		consensus.priv_validator.remote_signer.server_address unix:///sock/gnokms.sock \
		-config-path /gnoland-data/config/config.toml
	docker compose run --rm gnoland gnoland secrets init \
		-data-dir /gnoland-data/secrets
	@echo ""
	@echo "Init complete. Before running 'make up':"
	@echo "  1. Edit gnoland-data/config/config.toml — set moniker and p2p.external_address"
	@echo "  2. Populate gnokms-data/keystore/ with your signing key (name must match GNOKMS_KEY_NAME in .env)"

genesis: ## Generate genesis.json (~200 MB, takes a few minutes)
	docker build --target builder -t gno-validator-builder .
	touch genesis.json
	docker run --rm \
		-v "$(CURDIR)/genesis.json:/gno/misc/deployments/gnoland1/genesis.json" \
		gno-validator-builder \
		bash -c "cd /gno/misc/deployments/gnoland1 && ./gen-genesis.sh"

build: ## Build Docker images
	docker compose build

up: ## Start all services
	docker compose up -d

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

update: build ## Rebuild images and restart (binary update)
	docker compose up -d
