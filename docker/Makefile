COMPOSE := docker compose -f docker-compose.yml
SERVICE := debian-shell-lab

.PHONY: help up down restart rebuild re logs ps config shell hellish bash-shell auto-shell image-shell check-shell

help:
	@echo "Docker lab commands:"
	@echo "  make -C docker shell         # Open hellish (from dist/hellish)"
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
	@echo "  make -C docker check-shell   # Verify dist/hellish runs on Debian trixie"
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
	@echo "[docker] Pruning stale images, build cache and volumes to free disk space..."
	@docker system prune -af --volumes 2>/dev/null || true
	@echo "[docker] Disk available before build: $$(df -h /var/lib/docker 2>/dev/null | awk 'NR==2{print $$4}' || df -h / | awk 'NR==2{print $$4}')"
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d

re: rebuild

logs:
	$(COMPOSE) logs -f --tail=100

ps:
	$(COMPOSE) ps

config:
	$(COMPOSE) config

# The 15GB floor here was sized for COMPILING hellish in the container (object
# trees, LTO temporaries, a vendored libft build). Nothing is compiled any more
# — the image is a runtime-only Debian plus a copied-in binary — so the guard
# is now just enough headroom to pull the base image and start a container.
shell:
	@test -x ../dist/hellish || { \
		echo "dist/hellish is missing — run 'make shell' in the repo root first."; \
		exit 1; }
	@avail=$$(df /home | awk 'NR==2 {print $$4}'); \
	if [ "$$avail" -lt 2097152 ]; then \
		echo ""; \
		echo "╔════════════════════════════════════════════════════════════════╗"; \
		echo "║  INSUFFICIENT DISK SPACE - CANNOT START CONTAINER              ║"; \
		echo "╚════════════════════════════════════════════════════════════════╝"; \
		echo ""; \
		echo "Current: $$((avail/1024))MB free (need 2GB minimum)"; \
		echo ""; \
		echo "RUN THIS FIRST: make -C docker cleanup"; \
		echo ""; \
		exit 1; \
	fi
	@echo "[docker] Starting hellish shell (dist/hellish)..."
	$(COMPOSE) run --rm --service-ports -e SHELL_MODE=hellish $(SERVICE)

hellish: shell

bash-shell:
	$(COMPOSE) run --rm --service-ports -e SHELL_MODE=bash $(SERVICE)

auto-shell:
	$(COMPOSE) run --rm --service-ports -e SHELL_MODE=auto $(SERVICE)

image-shell:
	$(COMPOSE) run --rm --entrypoint bash $(SERVICE)

# Verify the binary that ACTUALLY ships in the ISO — dist/hellish, downloaded
# from the hellish release by `make shell` — runs on Debian trixie. That is the
# same distro the VM installs, so this is a direct rehearsal of the VM's login
# shell: it catches a missing libreadline.so.8 or a too-new glibc floor before
# the ISO is ever built. (It used to compile sh42 from source in here; that
# submodule is gone, and building a binary is not what we needed to test.)
check-shell:
	@echo "[container] Verifying the shipped hellish binary on Debian trixie..."
	@test -x ../dist/hellish || { \
		echo "dist/hellish is missing — run 'make shell' in the repo root first."; \
		exit 1; }
	$(COMPOSE) run --rm --entrypoint bash $(SERVICE) -lc '\
		set -e; \
		echo "--- distro ---"; . /etc/os-release; echo "$$PRETTY_NAME"; \
		echo "--- binary info ---"; ls -l /work/dist/hellish; \
		echo "--- shared libs ---"; ldd /work/dist/hellish; \
		if ldd /work/dist/hellish | grep -q "not found"; then \
			echo "FAIL: unresolved shared library in this distro"; exit 1; \
		fi; \
		echo "--- quick test ---"; \
		test "$$(/work/dist/hellish -c "echo works")" = "works"; \
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