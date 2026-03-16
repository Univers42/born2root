COMPOSE := docker compose -f docker-compose.yml
SERVICE := debian-shell-lab

.PHONY: help up down restart rebuild re logs ps config shell hellish bash-shell auto-shell image-shell check-shell

help:
	@echo "Docker lab commands:"
	@echo "  make -C docker shell         # Build + open hellish shell"
	@echo "  make -C docker bash-shell    # Open bash shell in container"
	@echo "  make -C docker image-shell   # Raw bash (skip init script)"
	@echo "  make -C docker rebuild       # Rebuild image from scratch"
	@echo ""
	@echo "Other commands:"
	@echo "  make -C docker up            # Build and start (detached)"
	@echo "  make -C docker down          # Stop and remove the container"
	@echo "  make -C docker restart       # Restart the lab container"
	@echo "  make -C docker re            # Quick rebuild (same as rebuild)"
	@echo "  make -C docker logs          # Follow container logs"
	@echo "  make -C docker ps            # Show lab container status"
	@echo "  make -C docker check-shell   # Verify hellish works inside container"
	@echo "  make -C docker cleanup       # Free disk space"
	@echo "  make -C docker disk-check    # Show disk status"

up:
	$(COMPOSE) up --build -d

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

rebuild:
	$(COMPOSE) down
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d

re: rebuild

logs:
	$(COMPOSE) logs -f --tail=100

ps:
	$(COMPOSE) ps

config:
	$(COMPOSE) config

shell:
	@avail=$$(df /home | awk 'NR==2 {print $$4}'); \
	if [ "$$avail" -lt 15728640 ]; then \
		echo ""; \
		echo "╔════════════════════════════════════════════════════════════════╗"; \
		echo "║  INSUFFICIENT DISK SPACE - CANNOT START CONTAINER              ║"; \
		echo "╚════════════════════════════════════════════════════════════════╝"; \
		echo ""; \
		echo "Current: $$((avail/1024))MB free (need 15GB minimum)"; \
		echo ""; \
		echo "RUN THIS FIRST: make -C docker cleanup"; \
		echo ""; \
		exit 1; \
	fi
	@echo "[docker] Building and starting hellish shell..."
	$(COMPOSE) run --rm --service-ports -e SHELL_MODE=hellish $(SERVICE)

hellish: shell

bash-shell:
	$(COMPOSE) run --rm --service-ports -e SHELL_MODE=bash $(SERVICE)

auto-shell:
	$(COMPOSE) run --rm --service-ports -e SHELL_MODE=auto $(SERVICE)

image-shell:
	$(COMPOSE) run --rm --entrypoint bash $(SERVICE)

check-shell:
	@echo "[container] Building and verifying hellish..."
	$(COMPOSE) run --rm -e SHELL_MODE=hellish --entrypoint bash $(SERVICE) -lc '\
		set -e; \
		cd /work/sh42 && make -j$$(nproc) && \
		echo "--- binary info ---" && \
		ls -l /work/sh42/build/bin/hellish && \
		ldd /work/sh42/build/bin/hellish | grep -E "not found|readline" || true && \
		echo "--- quick test ---" && \
		echo "echo hello" | /work/sh42/build/bin/hellish -c "echo works" && \
		echo "--- OK ---"'

cleanup:
	@echo "Freeing disk space..."
	@echo "Removing ~/Videos..."
	@rm -rf ~/Videos/* 2>/dev/null || echo "  (no Videos directory)"
	@echo "Removing ~/Downloads..."
	@rm -rf ~/Downloads/* 2>/dev/null || echo "  (no Downloads directory)"
	@echo "Pruning Docker..."
	@docker system prune -af --volumes > /dev/null 2>&1 || true
	@echo "Done. New disk status:"
	@make disk-check

disk-check:
	@avail=$$(df /home | awk 'NR==2 {print $$4}'); \
	echo "Disk usage in /home:"; \
	df -h /home | head -2; \
	echo ""; \
	echo "Top 10 largest directories in ~:"; \
	du -sh ~/* 2>/dev/null | sort -rh | head -10; \
	echo ""; \
	if [ "$$avail" -lt 15728640 ]; then \
		echo "⚠️  ALERT: Only $$((avail/1024))MB free (need 15GB for docker shell)"; \
		echo "Run: make -C docker cleanup"; \
	else \
		echo "✓ OK: $$((avail/1024))MB free (safe to run 'make -C docker shell')"; \
	fi