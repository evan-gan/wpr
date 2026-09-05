ROOT := $(shell pwd)
BIN  := $(HOME)/.local/bin/wp

.PHONY: build release install dev vendor

build:
	swift build

vendor:
	git submodule update --init
	bun install --cwd hosts/web
	bun install --cwd vendor/cosmos --no-save
	bun run --cwd vendor/cosmos build

release:
	swift build -c release

install: release
	mkdir -p "$(HOME)/.local/bin" "$(HOME)/.config/wp"
	ln -sf "$(ROOT)/.build/release/wp" "$(BIN)"
	printf '%s\n' "$(ROOT)" > "$(HOME)/.config/wp/root"
	@echo "installed $(BIN) -> $(ROOT)"

dev: build
	.build/debug/wp $(ARGS)
