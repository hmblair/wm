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
	@# The daemon applies its managed macOS settings (native tiling, Space
	@# reordering, Switch-to-Desktop shortcuts, window corner radius) on start
	@# and reverts them on stop — see SystemSettings.swift and `wm reset`.
	@echo "Installed to $(APP_DIR)"
	@echo "Linked CLI to $(CLI_LINK)"
	@echo "Run 'wm start' to start the service."

uninstall: unload
	@# Revert every wm-managed system setting. `unload` already SIGTERMs the
	@# daemon (which reverts on clean exit); this runs the installed binary once
	@# more as a backstop before removal, covering a prior hard kill that
	@# skipped the shutdown handler.
	-"$(BINARY)" reset
	rm -rf $(APP_DIR)
	rm -f $(CLI_LINK)
	rm -f $(LAUNCHD_DIR)/$(PLIST_NAME)
	@echo "Removed wm and reverted managed system settings."

load:
	launchctl load -w $(LAUNCHD_DIR)/$(PLIST_NAME)

unload:
	-launchctl unload -w $(LAUNCHD_DIR)/$(PLIST_NAME) 2>/dev/null

restart: unload load

clean:
	swift package clean
