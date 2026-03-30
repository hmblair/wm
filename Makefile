PREFIX ?= $(HOME)/.local
APP_NAME = focus-follows-mouse.app
APP_DIR = $(PREFIX)/$(APP_NAME)
BINARY = $(APP_DIR)/Contents/MacOS/focus-follows-mouse
SIGNING_IDENTITY ?= focus-follows-mouse
PLIST_NAME = com.hmblair.focus-follows-mouse.plist
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
	cp .build/release/focus-follows-mouse $(BINARY)
	cp resources/Info.plist $(APP_DIR)/Contents/Info.plist
	codesign --force --sign "$(SIGNING_IDENTITY)" $(APP_DIR)
	@mkdir -p $(LAUNCHD_DIR)
	@sed 's|__BINARY_PATH__|$(BINARY)|g' \
		resources/$(PLIST_NAME) > $(LAUNCHD_DIR)/$(PLIST_NAME)
	@defaults write -g EnableTilingByEdgeDrag -bool false
	@defaults write -g EnableTopTilingByEdgeDrag -bool false
	@defaults write -g EnableTilingOptionAccelerator -bool false
	@defaults write com.apple.dock mru-spaces -bool false && killall Dock
	@# Set Ctrl+1 through Ctrl+9 as "Switch to Desktop N" shortcuts
	@defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 118 '{ enabled = 1; value = { parameters = (49, 18, 262144); type = standard; }; }'
	@defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 119 '{ enabled = 1; value = { parameters = (50, 19, 262144); type = standard; }; }'
	@defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 120 '{ enabled = 1; value = { parameters = (51, 20, 262144); type = standard; }; }'
	@defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 121 '{ enabled = 1; value = { parameters = (52, 21, 262144); type = standard; }; }'
	@defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 122 '{ enabled = 1; value = { parameters = (53, 23, 262144); type = standard; }; }'
	@defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 123 '{ enabled = 1; value = { parameters = (54, 22, 262144); type = standard; }; }'
	@defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 124 '{ enabled = 1; value = { parameters = (55, 26, 262144); type = standard; }; }'
	@defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 125 '{ enabled = 1; value = { parameters = (56, 28, 262144); type = standard; }; }'
	@defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 126 '{ enabled = 1; value = { parameters = (57, 25, 262144); type = standard; }; }'
	@echo "Disabled macOS built-in tiling and automatic Space reordering."
	@echo "Set Ctrl+1 through Ctrl+9 as Switch to Desktop shortcuts."
	@echo "Installed to $(APP_DIR)"
	@echo "Run 'make load' to start the service."

uninstall: unload
	rm -rf $(APP_DIR)
	rm -f $(LAUNCHD_DIR)/$(PLIST_NAME)

load:
	launchctl load -w $(LAUNCHD_DIR)/$(PLIST_NAME)

unload:
	-launchctl unload -w $(LAUNCHD_DIR)/$(PLIST_NAME) 2>/dev/null

restart: unload load

clean:
	swift package clean
