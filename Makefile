PREFIX ?= /opt/homebrew

.PHONY: build install uninstall clean

build:
	swift build -c release

install: build
	cp .build/release/focus-follows-mouse $(PREFIX)/bin/focus-follows-mouse

uninstall:
	rm -f $(PREFIX)/bin/focus-follows-mouse

clean:
	swift package clean
