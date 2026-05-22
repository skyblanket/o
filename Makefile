# O v4 — build the swarmd daemon
SWARMRT ?= /Users/sky/swarmrt
SWC     := $(SWARMRT)/bin/swc

SRC_DIR := src
BIN     := bin/swarmd
SOURCES := $(wildcard $(SRC_DIR)/*.sw)

PREFIX  ?= $(HOME)/.local
DATADIR := $(HOME)/.o

.PHONY: all clean run install seed

all: $(BIN)

$(BIN): $(SOURCES)
	@mkdir -p bin
	$(SWC) build $(SRC_DIR)/main.sw -o $(BIN)
	@echo "O v4: built $(BIN)"

clean:
	rm -rf bin

run: $(BIN)
	./$(BIN)

# Install the daemon onto PATH and the dashboard into ~/.o/web.
install: $(BIN)
	@mkdir -p $(PREFIX)/bin $(DATADIR)/web
	cp $(BIN) $(PREFIX)/bin/swarmd
	cp web/dashboard.html $(DATADIR)/web/dashboard.html
	@echo "installed: $(PREFIX)/bin/swarmd"
	@echo "run 'swarmd', then open http://localhost:4100"

# Seed an example company so there is something to watch.
seed:
	@./scripts/seed-example.sh
