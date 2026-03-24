PREFIX ?= /opt/homebrew
PLIST_NAME = com.hmblair.focus-follows-mouse.plist
LAUNCHD_DIR = $(HOME)/Library/LaunchAgents

.PHONY: build install uninstall clean load unload restart

build:
	swift build -c release

install: build
	cp .build/release/focus-follows-mouse $(PREFIX)/bin/focus-follows-mouse
	@mkdir -p $(LAUNCHD_DIR)
	@sed 's|/opt/homebrew/bin/focus-follows-mouse|$(PREFIX)/bin/focus-follows-mouse|g' \
		resources/$(PLIST_NAME) > $(LAUNCHD_DIR)/$(PLIST_NAME)
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
