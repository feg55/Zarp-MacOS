# Common tasks. `make help` lists them. Nothing here needs root except `integration`.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Xcode runs with a minimal PATH; add the usual Homebrew and Go locations.
export PATH := /opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:$(PATH)

.PHONY: help test test-go test-swift check-docs fmt project build dmg integration notices icon clean

help: ## List the targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-13s %s\n", $$1, $$2}'

test: test-go test-swift check-docs ## Everything that needs neither root nor a network

test-go: ## Go: gofmt check, vet, tests with the race detector
	@cd zarpd && test -z "$$(gofmt -l .)" || { gofmt -l .; echo "gofmt needed (make fmt)"; exit 1; }
	cd zarpd && go vet ./... && go test -race -count=1 ./...

test-swift: ## Swift: the ZarpCore and ZarpdIPC test suites
	cd Packages/ZarpCore && swift test

check-docs: ## Markdown: every relative link and anchor must resolve
	python3 scripts/check-docs.py

fmt: ## gofmt -w the Go code
	cd zarpd && gofmt -w .

project: ## Generate Zarp.xcodeproj from project.yml
	xcodegen generate

build: project ## Unsigned Release build of the app (what CI checks)
	xcodebuild -project Zarp.xcodeproj -scheme Zarp -configuration Release \
	  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
	  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO build

dmg: ## Signed, packaged disk image in build/ (needs your signing team; docs/RELEASING.md)
	scripts/package.sh

integration: ## Real-network test of the daemon. Turn other VPNs OFF first; asks for sudo
	scripts/test-integration.sh

notices: ## Regenerate Resources/Licenses (third-party notices, bundled LICENSE)
	scripts/gen-notices.sh

icon: ## Redraw the app icon and the README / social-preview images
	swift scripts/make-icon.swift appiconset App/Sources/Zarp/Assets.xcassets/AppIcon.appiconset
	swift scripts/make-icon.swift png docs/images/icon.png 256
	swift scripts/make-icon.swift social docs/images/social-preview.png

clean: ## Remove build output and the generated Xcode project
	rm -rf build Zarp.xcodeproj
