.PHONY: init add-key build up down restart logs logs-gnoland logs-gnokms status update .check-env

.check-env:
	@test -f .env || (echo "Error: .env not found. Run: cp .env.example .env" && exit 1)

init: .check-env build ## First-time setup: build images, init node config/secrets
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

add-key: ## Add a signing key to the gnokms keystore (usage: make add-key KEYNAME=<name>)
	@test -n "$(KEYNAME)" || (echo "Error: KEYNAME is required. Usage: make add-key KEYNAME=<name>" && exit 1)
	@mkdir -p gnokms-data/keystore
	gnokey add $(KEYNAME) --home gnokms-data/keystore

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
