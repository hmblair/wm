PREFIX ?= $(HOME)/.local
APP_NAME = wm.app
APP_DIR = $(PREFIX)/$(APP_NAME)
BINARY = $(APP_DIR)/Contents/MacOS/wm
BIN_DIR = $(PREFIX)/bin
CLI_LINK = $(BIN_DIR)/wm
# Local self-signed code-signing certificate name. Left as-is so existing
# installs keep signing; change it only if you create a cert with a new name.
SIGNING_IDENTITY ?= focus-follows-mouse
PLIST_NAME = com.hmblair.wm.plist
LAUNCHD_DIR = $(HOME)/Library/LaunchAgents
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "unknown")
VERSION_FILE = Sources/Version.swift

.DEFAULT_GOAL := build
.PHONY: build install uninstall clean load unload start stop restart

$(VERSION_FILE): .git/HEAD .git/index
	@echo 'let appVersion = "$(VERSION)"' > $(VERSION_FILE)

build: $(VERSION_FILE)
	swift build -c release

install: build
	@mkdir -p $(APP_DIR)/Contents/MacOS
	cp .build/release/wm $(BINARY)
	cp resources/Info.plist $(APP_DIR)/Contents/Info.plist
	codesign --force --sign "$(SIGNING_IDENTITY)" $(APP_DIR)
	@# Symlink the binary onto PATH so `wm status` etc. can be run as a CLI.
	@mkdir -p $(BIN_DIR)
	@ln -sf $(BINARY) $(CLI_LINK)
	@mkdir -p $(LAUNCHD_DIR)
	@sed 's|__BINARY_PATH__|$(BINARY)|g' \
		resources/$(PLIST_NAME) > $(LAUNCHD_DIR)/$(PLIST_NAME)
	@defaults write -g EnableTilingByEdgeDrag -bool false
	@defaults write -g EnableTopTilingByEdgeDrag -bool false
	@defaults write -g EnableTilingOptionAccelerator -bool false
	@defaults write com.apple.dock mru-spaces -bool false && killall Dock
	@# Set Ctrl+1 through Ctrl+9 as "Switch to Desktop N" shortcuts. macOS only
	@# honors these when stored with the right types — a boolean <enabled> and
	@# integer <parameters> (ascii, keycode, modifier). Old-style plist syntax
	@# ({ enabled = 1; parameters = (...); }) writes them as strings, which the
	@# hotkey subsystem silently ignores. Keycodes match spaceKeyCodes (Space.swift).
	@for triple in 118:49:18 119:50:19 120:51:20 121:52:21 122:53:23 123:54:22 124:55:26 125:56:28 126:57:25; do \
		id=$${triple%%:*}; rest=$${triple#*:}; ascii=$${rest%%:*}; kc=$${rest#*:}; \
		defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add $$id "<dict><key>enabled</key><true/><key>value</key><dict><key>type</key><string>standard</string><key>parameters</key><array><integer>$$ascii</integer><integer>$$kc</integer><integer>262144</integer></array></dict></dict>"; \
	done
	@# Reload the symbolic hotkeys so the shortcuts take effect now, without a
	@# logout. The defaults above only update the plist; the hotkey subsystem
	@# keeps its own cached copy until this forces a re-read.
	@/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
	@echo "Disabled macOS built-in tiling and automatic Space reordering."
	@echo "Set Ctrl+1 through Ctrl+9 as Switch to Desktop shortcuts."
	@echo "Installed to $(APP_DIR)"
	@echo "Linked CLI to $(CLI_LINK)"
	@echo "Run 'make load' to start the service."

uninstall: unload
	rm -rf $(APP_DIR)
	rm -f $(CLI_LINK)
	rm -f $(LAUNCHD_DIR)/$(PLIST_NAME)

load:
	launchctl load -w $(LAUNCHD_DIR)/$(PLIST_NAME)

unload:
	-launchctl unload -w $(LAUNCHD_DIR)/$(PLIST_NAME) 2>/dev/null

restart: unload load

clean:
	swift package clean
