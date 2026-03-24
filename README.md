# focus-follows-mouse

Focus-follows-mouse for macOS tiling window managers.

A lightweight Swift daemon that focuses whichever window the mouse cursor moves over, and warps the mouse to a window when focus changes via keyboard (e.g., from a tiling WM keybinding).

## Requirements

- macOS 13+
- Accessibility permissions (System Settings → Privacy & Security → Accessibility)

## Install

```
make install
```

This builds a release binary and copies it to `/opt/homebrew/bin/`. Override the install prefix with `PREFIX=/usr/local make install`.

## Usage

```
focus-follows-mouse [--verbose|-v] [--dump] [--no-tile]
```

| Flag | Description |
|------|-------------|
| `--verbose`, `-v` | Print timestamped debug output to stderr |
| `--dump` | Dump window info for the current space and exit |
| `--no-tile` | Disable the built-in tiling window manager |

### Running as a launchd service (recommended)

`make install` copies the binary and installs a launchd plist that starts the daemon at login and restarts it on crash:

```
make install
make load
```

To stop and remove:

```
make unload    # stop the service
make uninstall # remove binary and plist
```

Logs are written to `/tmp/focus-follows-mouse.log`.

### Running manually

```
focus-follows-mouse
```

The process runs in the foreground and exits cleanly on SIGINT/SIGTERM.
## How it works

- **Mouse tracking**: A `CGEvent` tap listens for mouse movement events.
- **Window lookup**: `CGWindowListCopyWindowInfo` provides on-screen window positions via CoreGraphics (no accessibility overhead).
- **Focusing**: The Accessibility API (`AXUIElement`) raises and focuses the window under the cursor.
- **Keyboard-driven focus**: When an external focus change is detected after a keypress (e.g., a WM keybinding moved focus), the mouse is warped to the newly focused window.
