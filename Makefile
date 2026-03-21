SHELL := /bin/bash

LNAV_VERSION := 0.13.2
HOST_UID     := $(shell id -u)
HOST_GID     := $(shell id -g)

.PHONY: init gen-identity print-infos build up down restart logs-gnoland logs-gnokms logs-telemetry status update reset .check-env .ensure-gnokms .ensure-gnoland .init-node-data

.check-env:
	@test -f .env || (echo "Error: .env not found. Run: cp .env.example .env" && exit 1)

init: .check-env build ## First-time setup: build images, init node config/secrets
	@mkdir -p gnoland-data/config gnoland-data/secrets gnokms-data/keystore
	docker compose run --rm --user $(HOST_UID):$(HOST_GID) gnoland gnoland config init -force \
		-config-path /gnoland-data/config/config.toml
	docker compose run --rm --user $(HOST_UID):$(HOST_GID) gnoland gnoland secrets init -force \
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
	@docker compose run --rm --no-deps --user $(HOST_UID):$(HOST_GID) gnoland gnoland config init \
		-config-path /gnoland-data/config/config.toml &>/dev/null || true
	@docker compose run --rm --no-deps --user $(HOST_UID):$(HOST_GID) gnoland gnoland secrets init \
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
			--user $(HOST_UID):$(HOST_GID) \
			--entrypoint gnokey \
			-v "$(CURDIR)/gnokms-data:/gnokms-data" \
			gno-validator-gnokms \
			add gnokms-docker-key --home /gnokms-data/keystore --insecure-password-stdin; \
	else \
		docker run --rm -it \
			--user $(HOST_UID):$(HOST_GID) \
			--entrypoint gnokey \
			-v "$(CURDIR)/gnokms-data:/gnokms-data" \
			gno-validator-gnokms \
			add gnokms-docker-key --home /gnokms-data/keystore; \
	fi

print-infos: .ensure-gnoland .ensure-gnokms .init-node-data ## Print node identity, network config, build metadata, and SHA-256 checksums
	@if [ -f config.overrides ]; then \
		docker run --rm \
			--entrypoint /apply-overrides.sh \
			-v "$(CURDIR)/gnoland-data:/gnoland-data" \
			-v "$(CURDIR)/config.overrides:/config.overrides:ro" \
			gno-validator-gnoland; \
	fi
	@echo "=== Identity ==="
	@docker run --rm \
		--entrypoint gnokey \
		-v "$(CURDIR)/gnokms-data:/gnokms-data" \
		gno-validator-gnokms \
		list --home /gnokms-data/keystore \
	| awk '{for(i=1;i<=NF;i++){if($$i=="addr:") addr=$$(i+1); if($$i=="pub:"){pub=$$(i+1); sub(/,$$/, "", pub)}} print "validator address: " addr "\nvalidator pub_key: " pub}'
	@echo "node_id:           $$(docker run --rm \
		-e GNOLAND_NTP_UPDATE= \
		-v "$(CURDIR)/gnoland-data:/gnoland-data" \
		gno-validator-gnoland \
		gnoland secrets get node_id.id --raw \
		-data-dir /gnoland-data/secrets)"
	@echo "moniker:           $$(docker run --rm \
		-e GNOLAND_NTP_UPDATE= \
		-v "$(CURDIR)/gnoland-data:/gnoland-data" \
		gno-validator-gnoland \
		gnoland config get moniker --raw \
		-config-path /gnoland-data/config/config.toml)"
	@echo ""
	@echo "=== Network Configuration ==="
	@echo "seeds:             $$(docker run --rm \
		-e GNOLAND_NTP_UPDATE= \
		-v "$(CURDIR)/gnoland-data:/gnoland-data" \
		gno-validator-gnoland \
		gnoland config get p2p.seeds --raw \
		-config-path /gnoland-data/config/config.toml)"
	@echo "persistent peers:  $$(docker run --rm \
		-e GNOLAND_NTP_UPDATE= \
		-v "$(CURDIR)/gnoland-data:/gnoland-data" \
		gno-validator-gnoland \
		gnoland config get p2p.persistent_peers --raw \
		-config-path /gnoland-data/config/config.toml)"
	@P2P_PORT=$$(grep -E '^GNOLAND_P2P_PORT=' .env 2>/dev/null | cut -d= -f2- | tr -d ' '); \
	P2P_PORT=$${P2P_PORT:-26656}; \
	echo "p2p listener:      tcp://0.0.0.0:$$P2P_PORT"
	@RPC_PORT=$$(grep -E '^GNOLAND_RPC_PORT=' .env 2>/dev/null | cut -d= -f2- | tr -d ' '); \
	RPC_PORT=$${RPC_PORT:-26657}; \
	echo "rpc listener:      tcp://0.0.0.0:$$RPC_PORT"
	@echo ""
	@echo "=== Build Information ==="
	@echo "gno commit:        $$(docker inspect --format '{{index .Config.Labels "gno.commit"}}' gno-validator-gnoland 2>/dev/null)"
	@echo "gno version:       $$(docker inspect --format '{{index .Config.Labels "gno.version"}}' gno-validator-gnoland 2>/dev/null)"
	@echo "gno repo:          $$(docker inspect --format '{{index .Config.Labels "gno.repo"}}' gno-validator-gnoland 2>/dev/null)"
	@echo "build date:        $$(docker inspect --format '{{index .Config.Labels "build.date"}}' gno-validator-gnoland 2>/dev/null)"
	@echo ""
	@echo "=== Binary Checksums (SHA-256) ==="
	@echo "gnoland:           $$(docker run --rm --entrypoint sha256sum gno-validator-gnoland /usr/local/bin/gnoland | awk '{print $$1}')"
	@echo "gnokey:            $$(docker run --rm --entrypoint sha256sum gno-validator-gnokms /usr/local/bin/gnokey | awk '{print $$1}')"
	@echo "gnokms:            $$(docker run --rm --entrypoint sha256sum gno-validator-gnokms /usr/local/bin/gnokms | awk '{print $$1}')"
	@echo ""
	@echo "=== File Checksums (SHA-256) ==="
	@if [ -f genesis.json ]; then \
		if command -v sha256sum >/dev/null 2>&1; then \
			echo "genesis.json:      $$(sha256sum genesis.json | awk '{print $$1}')"; \
		else \
			echo "genesis.json:      $$(shasum -a 256 genesis.json | awk '{print $$1}')"; \
		fi; \
	else \
		echo "genesis.json:      (not found)"; \
	fi

build: ## Build Docker images (uses cache; rebuilds automatically when a new commit is available on the target branch)
	@GNO_REPO=$$(grep -E '^GNO_REPO=' .env 2>/dev/null | cut -d= -f2- | tr -d ' '); \
	GNO_REPO=$${GNO_REPO:-gnolang/gno}; \
	GNO_VERSION=$$(grep -E '^GNO_VERSION=' .env 2>/dev/null | cut -d= -f2- | tr -d ' '); \
	GNO_VERSION=$${GNO_VERSION:-master}; \
	echo "Resolving commit hash for $${GNO_VERSION} on $${GNO_REPO}..."; \
	GNO_COMMIT=$$(git ls-remote https://github.com/$${GNO_REPO}.git $${GNO_VERSION} 2>/dev/null | awk '{print $$1}'); \
	if [ -z "$$GNO_COMMIT" ]; then \
		echo "Warning: could not resolve $${GNO_VERSION} to a commit hash (no network or direct commit?), cache may be stale"; \
		GNO_COMMIT=$$GNO_VERSION; \
	fi; \
	echo "Building gno@$${GNO_COMMIT:0:12} ($${GNO_VERSION} on $${GNO_REPO})"; \
	export GNO_COMMIT_HASH=$$GNO_COMMIT; \
	export BUILD_DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ); \
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
		TERM=xterm-256color .lnav/bin/lnav -I ./.lnav docker://gno-validator-gnoland-1; \
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
