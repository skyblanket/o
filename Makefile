# O v4 — build, install, run
#
# SWARMRT points at a swarmrt checkout. The default assumes the
# sibling-checkout convention: clone github.com/skyblanket/swarmrt
# next to this repo so that ../swarmrt resolves from the repo root.
# Override with `make SWARMRT=/path/to/swarmrt` if it lives elsewhere.
SWARMRT ?= ../swarmrt
SWC     := $(SWARMRT)/bin/swc

SRC_DIR := src
BIN     := bin/swarmd
SOURCES := $(wildcard $(SRC_DIR)/*.sw)

PREFIX  ?= $(HOME)/.local
DATADIR := $(HOME)/.o

.PHONY: all clean run install seed dev stop-dev logs check

all: $(BIN)

# Hermetic test suite — builds, boots a throwaway daemon on a random
# port + temp DB, and drives the REST pipeline end to end.
check: $(BIN)
	@./scripts/check.sh

$(BIN): $(SOURCES)
	@test -x "$(SWC)" || { \
	  echo "error: swarmrt compiler not found at $(SWC)"; \
	  echo "clone github.com/skyblanket/swarmrt as a sibling of this repo,"; \
	  echo "or build with: make SWARMRT=/path/to/swarmrt"; \
	  exit 1; }
	@mkdir -p bin
	$(SWC) build $(SRC_DIR)/main.sw -o $(BIN)
	@echo "O v4: built $(BIN)"

clean:
	rm -rf bin

# Foreground run — for development of the daemon itself.
run: $(BIN)
	./$(BIN)

# Install the daemon binary onto PATH.
install: $(BIN)
	@mkdir -p $(PREFIX)/bin
	cp $(BIN) $(PREFIX)/bin/swarmd
	@echo "installed: $(PREFIX)/bin/swarmd"
	@echo "run 'make dev' to start daemon + UI together."

# Bring up swarmd + Vite as managed background processes with
# auto-restart on crash. Survive shell cleanup. Run once and forget.
dev:
	@./scripts/dev.sh

stop-dev:
	@./scripts/stop.sh

logs:
	@echo "=== daemon (tail 25) ==="; tail -25 $(DATADIR)/daemon.log 2>/dev/null || echo "(no daemon.log — run make dev)"
	@echo
	@echo "=== ui (tail 25) ==="; tail -25 $(DATADIR)/ui.log 2>/dev/null || echo "(no ui.log — run make dev)"

# Seed an example company so there is something to watch.
seed:
	@./scripts/seed-example.sh
