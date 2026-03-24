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
| `--version` | Print version and exit |

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

Logs are available via macOS unified logging:

```
log stream --predicate 'subsystem == "com.hmblair.focus-follows-mouse"' --level debug
```

Startup errors are also written to `/tmp/focus-follows-mouse.log`.

### Running manually

```
focus-follows-mouse
```

The process runs in the foreground and exits cleanly on SIGINT/SIGTERM.

## Configuration

Configuration is read from `~/.config/focus-follows-mouse/config.toml`. All fields are optional and fall back to sensible defaults.

```toml
# Gap in points between tiled windows (default: 8)
gap = 8

# How often to poll for window changes, in seconds (default: 0.016)
poll_interval = 0.016

# Apps whose windows are completely invisible to the daemon.
# They won't be focused, tiled, or tracked in any way.
ignored_apps = ["borders", "Hammerspoon", "Alfred", "Raycast"]

# Apps that participate in focus-follows-mouse but are excluded
# from tiling (their windows keep whatever size/position they have).
excluded_apps = ["Stickies"]

[keybindings]
# Set to false to disable all built-in keybindings (default: true)
enabled = true

# Modifier keys for directional focus (Cmd + arrow keys by default)
[keybindings.focus_modifier]
cmd = true

# Modifier keys for directional window swap (Cmd+Shift + arrow keys by default)
[keybindings.swap_modifier]
cmd = true
shift = true
```

### Keybindings

When enabled, the daemon intercepts arrow key presses with the configured modifiers:

| Binding | Action |
|---------|--------|
| focus_modifier + arrow | Move focus to the nearest window in that direction |
| swap_modifier + arrow | Swap the focused window with its neighbor in that direction |

Each modifier is a combination of `cmd`, `shift`, `ctrl`, and `option` (all `false` by default). The match is exact: only the specified modifiers must be held.

## How it works

- **Mouse tracking**: A `CGEvent` tap listens for mouse movement events.
- **Window lookup**: `CGWindowListCopyWindowInfo` provides on-screen window positions via CoreGraphics (no accessibility overhead).
- **Focusing**: The Accessibility API (`AXUIElement`) raises and focuses the window under the cursor.
- **Keyboard-driven focus**: When an external focus change is detected after a keypress (e.g., a WM keybinding moved focus), the mouse is warped to the newly focused window.
