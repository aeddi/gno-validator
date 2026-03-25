SHELL := /bin/bash

.PHONY: up down restart logs status .check-env

.check-env:
	@test -f .env || (echo "Error: .env not found. Run: cp .env.example .env" && exit 1)
	@grep -qE '^DOMAIN=.+' .env || (echo "Error: DOMAIN is not set in .env" && exit 1)

up: .check-env ## Start Caddy
	@set -a && source .env && set +a && envsubst '$$DOMAIN' < www/index.html.tmpl > www/index.html
	docker compose up -d

down: ## Stop and remove containers
	docker compose down

restart: ## Reload Caddyfile without downtime
	docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile

logs: ## Follow Caddy logs
	docker compose logs -f caddy

status: ## Show container status
	docker compose ps
