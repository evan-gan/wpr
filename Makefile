ROOT := $(shell pwd)
BIN  := $(HOME)/.local/bin/wpr

.PHONY: build release install dev

build:
	swift build

release:
	swift build -c release

install: release
	mkdir -p "$(HOME)/.local/bin" "$(HOME)/.config/wp"
	ln -sf "$(ROOT)/.build/release/wpr" "$(BIN)"
	printf '%s\n' "$(ROOT)" > "$(HOME)/.config/wp/root"
	@echo "installed $(BIN) -> $(ROOT)"

dev: build
	.build/debug/wpr $(ARGS)
