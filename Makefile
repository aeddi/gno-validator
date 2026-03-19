SHELL := /bin/bash

LNAV_VERSION := 0.13.2

.PHONY: init gen-identity print-identity build up down restart logs-gnoland logs-gnokms logs-telemetry status update reset .check-env .ensure-gnokms .ensure-gnoland .init-node-data

.check-env:
	@test -f .env || (echo "Error: .env not found. Run: cp .env.example .env" && exit 1)

init: .check-env build ## First-time setup: build images, init node config/secrets
	@mkdir -p gnoland-data/config gnoland-data/secrets gnokms-data/keystore
	docker compose run --rm gnoland gnoland config init -force \
		-config-path /gnoland-data/config/config.toml
	docker compose run --rm gnoland gnoland secrets init -force \
		-data-dir /gnoland-data/secrets
	@echo ""
	@echo "Init complete. Before running 'make up':"
	@echo "  1. cp config.overrides.example config.overrides — set moniker, p2p.external_address, p2p.seeds, p2p.persistent_peers"
	@echo "  2. Copy genesis.json to the repo root"
	@echo ""
	@echo "  Note: config.overrides is applied on each start. Mandatory settings (remote signer,"
	@echo "        telemetry) are applied after and will override any conflicting entries."

.ensure-gnokms:
	@docker image inspect gno-validator-gnokms >/dev/null 2>&1 || \
		(echo "Building gnokms image, please wait..." && docker compose build gnokms)

.ensure-gnoland:
	@docker image inspect gno-validator-gnoland >/dev/null 2>&1 || \
		(echo "Building gnoland image, please wait..." && docker compose build gnoland)

.init-node-data: .ensure-gnoland
	@mkdir -p gnoland-data/config gnoland-data/secrets gnokms-data/keystore
	@docker compose run --rm --no-deps gnoland gnoland config init \
		-config-path /gnoland-data/config/config.toml &>/dev/null || true
	@docker compose run --rm --no-deps gnoland gnoland secrets init \
		-data-dir /gnoland-data/secrets &>/dev/null || true

.lnav/bin/lnav:
	@rm -f .lnav/bin/lnav.zip; rm -rf .lnav/bin/lnav-$(LNAV_VERSION); \
	mkdir -p .lnav/bin; \
	if command -v curl >/dev/null 2>&1; then FETCH="curl -fsSL -o"; \
	elif command -v wget >/dev/null 2>&1; then FETCH="wget -q -O"; \
	else echo "Error: curl or wget is required to download lnav" >&2; exit 1; fi; \
	if ! command -v unzip >/dev/null 2>&1; then echo "Error: unzip is required to extract lnav" >&2; exit 1; fi; \
	OS=$$(uname -s); ARCH=$$(uname -m); \
	case "$$OS/$$ARCH" in \
		Darwin/arm64)  ZIP=lnav-$(LNAV_VERSION)-aarch64-macos.zip ;; \
		Darwin/*)      ZIP=lnav-$(LNAV_VERSION)-x86_64-macos.zip ;; \
		Linux/aarch64) ZIP=lnav-$(LNAV_VERSION)-linux-musl-arm64.zip ;; \
		Linux/*)       ZIP=lnav-$(LNAV_VERSION)-linux-musl-x86_64.zip ;; \
		*)             echo "Error: unsupported platform $$OS/$$ARCH" >&2; exit 1 ;; \
	esac; \
	echo "Downloading lnav v$(LNAV_VERSION)..."; \
	$$FETCH .lnav/bin/lnav.zip "https://github.com/tstack/lnav/releases/download/v$(LNAV_VERSION)/$$ZIP" && \
	unzip -q .lnav/bin/lnav.zip "lnav-$(LNAV_VERSION)/lnav" -d .lnav/bin && \
	mv .lnav/bin/lnav-$(LNAV_VERSION)/lnav .lnav/bin/lnav && \
	rm -rf .lnav/bin/lnav.zip .lnav/bin/lnav-$(LNAV_VERSION) && \
	chmod +x .lnav/bin/lnav && \
	echo "lnav installed at .lnav/bin/lnav"

gen-identity: .ensure-gnokms ## Generate the validator signing identity in the gnokms keystore
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

print-identity: .ensure-gnokms .ensure-gnoland .init-node-data ## Print the validator identity (address and public key) from the keystore
	@docker run --rm \
		--entrypoint gnokey \
		-v "$(CURDIR)/gnokms-data:/gnokms-data" \
		gno-validator-gnokms \
		list --home /gnokms-data/keystore \
	| awk '{for(i=1;i<=NF;i++){if($$i=="addr:") addr=$$(i+1); if($$i=="pub:"){pub=$$(i+1); sub(/,$$/, "", pub)}} print "validator_address: " addr "\nvalidator_pub_key: " pub}'
	@if [ -f config.overrides ]; then \
		docker run --rm \
			--entrypoint /apply-overrides.sh \
			-v "$(CURDIR)/gnoland-data:/gnoland-data" \
			-v "$(CURDIR)/config.overrides:/config.overrides:ro" \
			gno-validator-gnoland; \
	fi
	@echo "node_id:           $$(docker run --rm \
		-v "$(CURDIR)/gnoland-data:/gnoland-data" \
		gno-validator-gnoland \
		gnoland secrets get node_id.id --raw \
		-data-dir /gnoland-data/secrets)"
	@echo "moniker:           $$(docker run --rm \
		-v "$(CURDIR)/gnoland-data:/gnoland-data" \
		gno-validator-gnoland \
		gnoland config get moniker --raw \
		-config-path /gnoland-data/config/config.toml)"

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

logs-gnoland: ## Open interactive log TUI (level filter + search) — downloads lnav on first run
	@if $(MAKE) -s .lnav/bin/lnav; then \
		.lnav/bin/lnav -I ./.lnav docker://gno-validator-gnoland-1; \
	else \
		echo "lnav unavailable, falling back to plain logs..."; \
		docker compose logs -f gnoland; \
	fi

logs-gnokms: ## Follow gnokms logs
	docker compose logs -f gnokms

logs-telemetry: ## Follow logs for all telemetry services
	docker compose logs -f otelcol tempo prometheus grafana

status: ## Show container status
	docker compose ps

reset: ## Reset node state: remove db and wal, reset priv_validator_state.json
	@echo "WARNING: This will erase the node state. Ensure the node is stopped ('make down') first."
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@echo "Resetting gnoland-data/db, gnoland-data/wal and gnoland-data/secrets/priv_validator_state.json"
	@rm -rf gnoland-data/db gnoland-data/wal
	@printf '{\n  "height": "0",\n  "round": "0",\n  "step": 0\n}\n' > gnoland-data/secrets/priv_validator_state.json

update: .check-env build ## Rebuild images and restart (binary update)
	@if ! grep -qE '^GNOKMS_PASSWORD=.+' .env 2>/dev/null; then \
		read -s -p "GNOKMS_PASSWORD: " pass && echo "" && \
		GNOKMS_PASSWORD="$$pass" docker compose up -d; \
	else \
		docker compose up -d; \
	fi
