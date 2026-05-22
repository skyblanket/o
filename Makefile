# O v4 — build the swarmd daemon
SWARMRT ?= /Users/sky/swarmrt
SWC     := $(SWARMRT)/bin/swc

SRC_DIR := src
BIN     := bin/swarmd
SOURCES := $(wildcard $(SRC_DIR)/*.sw)

.PHONY: all clean run

all: $(BIN)

$(BIN): $(SOURCES)
	@mkdir -p bin
	$(SWC) build $(SRC_DIR)/main.sw -o $(BIN)
	@echo "O v4: built $(BIN)"

clean:
	rm -rf bin

run: $(BIN)
	./$(BIN)
