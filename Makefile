ROOT := $(shell pwd)
BIN  := $(HOME)/.local/bin/wpr

.PHONY: build release install dev vendor

build:
	swift build

vendor:
	git submodule update --init
	bun install --cwd hosts/web
	bun install --cwd vendor/cosmos --no-save
	bun run --cwd vendor/cosmos build
	bun install --cwd vendor/monolith-terrain --no-save
	# bun writes a lockfile even with --no-save; keep the submodules clean
	rm -f vendor/*/bun.lock

release:
	swift build -c release

install: release
	mkdir -p "$(HOME)/.local/bin" "$(HOME)/.config/wp"
	ln -sf "$(ROOT)/.build/release/wpr" "$(BIN)"
	printf '%s\n' "$(ROOT)" > "$(HOME)/.config/wp/root"
	@echo "installed $(BIN) -> $(ROOT)"

dev: build
	.build/debug/wpr $(ARGS)
