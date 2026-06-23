# wm

A lightweight macOS daemon that provides focus-follows-mouse behavior, a BSP tiling window manager, and a menu bar space indicator.

## Requirements

- macOS 13+
- Accessibility permissions (System Settings → Privacy & Security → Accessibility)

## Install

```
make install
make load
```

This builds a release binary, installs it as an app bundle at `~/.local/wm.app`, starts it as a launchd service, and disables macOS built-in tiling and automatic Space reordering.

Override the install prefix with `PREFIX=/usr/local make install`.

To stop and remove:

```
make unload    # stop the service
make uninstall # remove binary and plist
```

## Usage

```
wm [command] [flags]
```

With no command, `wm` runs as the window-manager daemon. The process runs in the foreground and exits cleanly on SIGINT/SIGTERM. When installed as a launchd service, it starts at login and restarts on crash.

| Command | Description |
|---------|-------------|
| `status` | Print daemon status, open Spaces, displays, and config (colorized) |
| `help` | Show usage |

| Flag | Description |
|------|-------------|
| `--verbose`, `-v` | Print timestamped debug output to stderr |
| `--dump` | Dump window info for the current space and exit |
| `--no-tile` | Disable the built-in tiling window manager |
| `--version` | Print version and exit |

`wm status` reports whether the daemon is running (and its pid), whether auto-start and Accessibility are enabled, the open Spaces with the active one highlighted, attached displays, and the loaded configuration. Colors are emitted only when stdout is a terminal.

Logs are available via macOS unified logging:

```
log stream --predicate 'subsystem == "com.hmblair.wm"' --level debug
```

## Configuration

Configuration is read from `~/.config/wm/config.toml`. All fields are optional. The file is watched for changes and reloaded automatically.

```toml
# Gap in points between tiled windows and screen edges (default: 8)
gap = 8

# How often to poll for window changes, in seconds (default: 0.016)
poll_interval = 0.016

# Show clickable space indicators in the menu bar (default: true)
status_bar = true

# Apps whose windows are completely invisible to the daemon.
# They won't be focused, tiled, or tracked in any way.
ignored_apps = ["borders", "Hammerspoon", "Alfred", "Raycast"]

# Apps that participate in focus-follows-mouse behavior but are excluded
# from tiling (their windows keep whatever size/position they have).
excluded_apps = ["Stickies"]

[keybindings]
# Set to false to disable all built-in keybindings (default: true)
enabled = true

# Modifier keys for directional focus (Cmd + arrow keys by default)
[keybindings.focus_modifier]
cmd = true

# Modifier keys for directional swap, rotate, and move-to-space
# (Cmd+Shift by default)
[keybindings.swap_modifier]
cmd = true
shift = true

# Modifier keys for move-to-space (Cmd+Shift by default)
[keybindings.move_to_space_modifier]
cmd = true
shift = true
```

## Keybindings

When enabled, the daemon intercepts key presses with the configured modifiers:

| Binding | Action |
|---------|--------|
| `focus_modifier` + arrow | Move focus to the nearest window in that direction |
| `swap_modifier` + arrow | Swap the focused window with its neighbor in that direction |
| `swap_modifier` + R | Rotate the split orientation of the focused window's parent |
| `move_to_space_modifier` + 1-9 | Move the focused window to the specified Space |

Each modifier is a combination of `cmd`, `shift`, `ctrl`, and `option` (all `false` by default). The match is exact: only the specified modifiers must be held.

## Features

### Focus follows mouse

A `CGEvent` tap tracks mouse movement. When the cursor enters a window, it is raised and focused via the Accessibility API. When the cursor moves to the desktop, focus is released to Finder.

### BSP tiling

Windows are arranged in a binary space partition (BSP) tree. New windows are inserted and the screen is recursively split. The layout respects window size constraints: windows with a minimum or maximum size (like System Settings or App Store) are detected reactively and the BSP split ratios are adjusted so constrained windows and their neighbors tile correctly.

Tiling is suspended during Mission Control and while the mouse button is held.

### Status bar

Clickable Space indicators appear in the menu bar showing all Spaces. The active Space is displayed in bold. Clicking a number switches to that Space.

### Keyboard navigation

Arrow-key bindings allow moving focus between windows, swapping window positions, rotating split orientation, and moving windows to other Spaces. The mouse is warped to the focused window after each action.
