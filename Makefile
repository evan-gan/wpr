ROOT := $(shell pwd)
BIN  := $(HOME)/.local/bin/wpr

.PHONY: build release install dev

build:
	swift build

release:
	swift build -c release

install: release
	mkdir -p "$(HOME)/.local/bin"
	ln -sf "$(ROOT)/.build/release/wpr" "$(BIN)"
	@echo "installed $(BIN) -> $(ROOT)"

dev: build
	.build/debug/wpr $(ARGS)
