PREFIX ?= /opt/homebrew
PLIST_NAME = com.hmblair.focus-follows-mouse.plist
LAUNCHD_DIR = $(HOME)/Library/LaunchAgents
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "unknown")
VERSION_FILE = Sources/Version.swift

.PHONY: build install uninstall clean load unload restart

$(VERSION_FILE): .git/HEAD .git/index
	@echo 'let appVersion = "$(VERSION)"' > $(VERSION_FILE)

build: $(VERSION_FILE)
	swift build -c release

install: build
	cp .build/release/focus-follows-mouse $(PREFIX)/bin/focus-follows-mouse
	@mkdir -p $(LAUNCHD_DIR)
	@sed 's|/opt/homebrew/bin/focus-follows-mouse|$(PREFIX)/bin/focus-follows-mouse|g' \
		resources/$(PLIST_NAME) > $(LAUNCHD_DIR)/$(PLIST_NAME)
	@defaults write -g EnableTilingByEdgeDrag -bool false
	@defaults write -g EnableTopTilingByEdgeDrag -bool false
	@defaults write -g EnableTilingOptionAccelerator -bool false
	@echo "Disabled macOS built-in tiling (logout required to take effect)."
	@echo "Installed launchd plist to $(LAUNCHD_DIR)/$(PLIST_NAME)"
	@echo "Run 'make load' to start the service."

uninstall: unload
	rm -f $(PREFIX)/bin/focus-follows-mouse
	rm -f $(LAUNCHD_DIR)/$(PLIST_NAME)

load:
	launchctl load -w $(LAUNCHD_DIR)/$(PLIST_NAME)

unload:
	-launchctl unload $(LAUNCHD_DIR)/$(PLIST_NAME) 2>/dev/null

restart: unload load

clean:
	swift package clean
