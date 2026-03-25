SHELL := /bin/bash

.PHONY: up down restart logs status .check-config

.check-config:
	@test -f config || (echo "Error: config not found. Run: cp config.example config" && exit 1)
	@grep -qE '^domain=.+' config || (echo "Error: domain is not set in config" && exit 1)

up: .check-config ## Start Caddy
	@set -e; \
	domain=$$(grep -E '^domain=' config | cut -d= -f2-); \
	mkdir -p caddy-data/www; \
	{ \
	  sed "s|__DOMAIN__|$$domain|g" templates/Caddyfile.tmpl | grep -v '__SERVICES__'; \
	  grep -E '^[^#]+=.+' config | grep -v '^domain=' | \
	    while IFS='=' read -r name port; do \
	      printf '\n%s.%s {\n\treverse_proxy localhost:%s\n}\n' "$$name" "$$domain" "$$port"; \
	    done; \
	} > caddy-data/Caddyfile; \
	while IFS= read -r line; do \
	  if [[ "$$line" == *__SERVICE_LIST__* ]]; then \
	    grep -E '^[^#]+=.+' config | grep -v '^domain=' | \
	      while IFS='=' read -r name port; do \
	        printf '        <li><a href="https://%s.%s">→ %s</a></li>\n' "$$name" "$$domain" "$$name"; \
	      done; \
	  else \
	    printf '%s\n' "$$line" | sed "s|__DOMAIN__|$$domain|g"; \
	  fi; \
	done < templates/index.html.tmpl > caddy-data/www/index.html; \
	docker compose up -d

down: ## Stop and remove containers
	docker compose down

restart: ## Reload Caddyfile without downtime
	docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile

logs: ## Follow Caddy logs
	docker compose logs -f caddy

status: ## Show container status
	docker compose ps
