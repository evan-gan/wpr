ROOT := $(shell pwd)
BIN  := $(HOME)/.local/bin/wpr
VERSION ?= $(shell git describe --tags --always 2>/dev/null)
DIST    := dist/wpr-$(VERSION)-macos.tar.gz

GIT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null)
DIRTY    := $(if $(GIT_HASH),$(shell git diff --quiet HEAD -- . ':!Sources/wpr/Version.swift' 2>/dev/null || echo -dirty))
DEV_VERSION := dev-$(GIT_HASH)$(DIRTY)
STAMP    = printf 'let version = "%s"\n' "$(1)" > Sources/wpr/Version.swift
UNSTAMP  = git checkout -q -- Sources/wpr/Version.swift 2>/dev/null || true

.PHONY: build release install dev dist

build:
	$(call STAMP,$(DEV_VERSION))
	swift build; $(UNSTAMP)

release:
	$(call STAMP,$(DEV_VERSION))
	swift build -c release; $(UNSTAMP)

install: release
	mkdir -p "$(HOME)/.local/bin"
	ln -sf "$(ROOT)/.build/release/wpr" "$(BIN)"
	@echo "installed $(BIN) -> $(ROOT)"

dev: build
	.build/debug/wpr $(ARGS)

dist:
	$(call STAMP,$(VERSION))
	swift build -c release --triple arm64-apple-macosx
	swift build -c release --triple x86_64-apple-macosx
	mkdir -p dist
	lipo -create .build/arm64-apple-macosx/release/wpr .build/x86_64-apple-macosx/release/wpr -output dist/wpr
	tar -czf $(DIST) -C dist wpr
	cd dist && shasum -a 256 $(notdir $(DIST)) | tee $(notdir $(DIST)).sha256
	$(UNSTAMP)
