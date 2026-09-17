ROOT    := $(shell pwd)
BIN     := $(HOME)/.local/bin/wpr
VERSION ?= $(shell git describe --tags --always)
DIST    := dist/wpr-$(VERSION)-macos.tar.gz

.PHONY: build release install dev dist

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

dist:
	swift build -c release --triple arm64-apple-macosx
	swift build -c release --triple x86_64-apple-macosx
	mkdir -p dist
	lipo -create .build/arm64-apple-macosx/release/wpr .build/x86_64-apple-macosx/release/wpr -output dist/wpr
	tar -czf $(DIST) -C dist wpr
	cd dist && shasum -a 256 $(notdir $(DIST)) | tee $(notdir $(DIST)).sha256
