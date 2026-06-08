# Cam Control for DJI Osmo — project shortcuts.
# `make help` lists everything. Targets are also the canonical commands for Claude.

PROJECT := OsmoMulti.xcodeproj
SCHEME := OsmoMulti
CONFIG := Debug
DERIVED := build
APP := $(DERIVED)/Build/Products/$(CONFIG)-iphoneos/OsmoMulti.app

# Build via the scheme + iOS destination so EACH target builds for its own
# platform. Do NOT use `-target X -sdk iphoneos`: that forces the embedded
# OsmoWatch target through the iOS SDK, which omits the WKApplication key and
# the device rejects the install with "InvalidWatchKitApp". Needs the watchOS
# SDK + runtime installed (see `make runtimes`).
XCBS := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'generic/platform=iOS' -configuration $(CONFIG) -derivedDataPath $(DERIVED)
NOSIGN := CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

.PHONY: help build build-ci gen signing-local test runtimes devices install install-watch deploy logs logs-watch clean

help: ## Show this help
	@sed \
		-e '/^[a-zA-Z0-9_\-]*:.*##/!d' \
		-e 's/:.*##\s*/:/' \
		-e 's/^\(..*\):\(.*\)/$(shell tput setaf 6)\1$(shell tput sgr0):\2/' \
		$(MAKEFILE_LIST) | column -c2 -t -s :

build: ## Signed Debug build for device (app + valid embedded watch app)
	$(XCBS) -allowProvisioningUpdates build

build-ci: ## Compile-only build, no signing (fast verify)
	$(XCBS) $(NOSIGN) build

gen: ## Regenerate OsmoMulti.xcodeproj from project.yml
	xcodegen generate

signing-local: ## Scaffold Config/Signing.local.xcconfig (local signing override) from the template
	@if [ -f Config/Signing.local.xcconfig ]; then \
		echo "Config/Signing.local.xcconfig already exists — leaving it alone."; \
	else \
		cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig; \
		echo "✓ Created Config/Signing.local.xcconfig — edit DEVELOPMENT_TEAM + BUNDLE_ID_PREFIX, then rebuild."; \
	fi

test: ## Compile DJIOsmoKit unit tests (no signing)
	xcodebuild -project $(PROJECT) -target DJIOsmoKitTests -sdk iphoneos -configuration $(CONFIG) $(NOSIGN) build

runtimes: ## Download iOS + watchOS simulator runtimes (needed for .icon / watch scheme)
	xcodebuild -downloadPlatform iOS
	xcodebuild -downloadPlatform watchOS

devices: ## List connected devices and their IDs
	xcrun devicectl list devices

install: ## Install app to iPhone — make install DEVICE=<id> (see 'make devices')
	@test -n "$(DEVICE)" || { echo "Usage: make install DEVICE=<device-id>  (run 'make devices' for IDs)"; exit 1; }
	xcrun devicectl device install app --device $(DEVICE) $(APP)

install-watch: ## Install watch app to watch — make install-watch DEVICE=<watch-id>
	@test -n "$(DEVICE)" || { echo "Usage: make install-watch DEVICE=<watch-id>  (run 'make devices' for IDs)"; exit 1; }
	xcrun devicectl device install app --device $(DEVICE) $(APP)/Watch/OsmoWatch.app

deploy: build install ## Build then install to iPhone — make deploy DEVICE=<id>

logs: ## Stream iPhone app logs
	log stream --predicate 'subsystem == "net.prehiti.payton.CamControl"' --level debug

logs-watch: ## Stream Watch app logs
	log stream --predicate 'subsystem == "net.prehiti.payton.CamControl.watchkitapp"' --level debug

clean: ## Remove build artifacts
	rm -rf build
