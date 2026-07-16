# wm

A lightweight macOS daemon that provides focus-follows-mouse behavior, a BSP tiling window manager, and a menu bar space indicator.

## Requirements

- macOS 13+
- Accessibility permissions (System Settings → Privacy & Security → Accessibility)

## Install

```
make install
wm start
```

This builds a release binary, installs it as an app bundle at `~/.local/wm.app`, symlinks the `wm` CLI into `~/.local/bin` (so `wm` works from the shell — ensure that directory is on your `PATH`), registers it as a launchd service, and disables macOS built-in tiling and automatic Space reordering.

Override the install prefix with `PREFIX=/usr/local make install`.

To stop the service or remove it entirely:

```
wm stop        # stop the service
make uninstall # remove binary and plist
```

## Usage

```
wm [command] [flags]
```

With no command, `wm` prints daemon status (see below). The `daemon` command runs the window manager itself in the foreground; it exits cleanly on SIGINT/SIGTERM, and the launchd service invokes it to start at login and restart on crash.

| Command | Description |
|---------|-------------|
| _(none)_ | Print daemon status, open Spaces, displays, and config (colorized) |
| `start` | Start the launchd service |
| `stop` | Stop the launchd service |
| `daemon` | Run the window manager in the foreground (used by launchd) |
| `help` | Show usage |

| Flag | Description |
|------|-------------|
| `--version` | Print version and exit |

The `daemon` command additionally accepts:

| Flag | Description |
|------|-------------|
| `--verbose`, `-v` | Print timestamped debug output to stderr |
| `--no-tile` | Disable the built-in tiling window manager |
| `--dump` | Dump window info for the current space and exit |

Run with no command, `wm` reports whether the daemon is running (and its pid), whether auto-start and Accessibility are enabled, the open Spaces with the active one highlighted, attached displays, and the loaded configuration. Colors are emitted only when stdout is a terminal.

Logs are available via macOS unified logging. Use the absolute path
`/usr/bin/log`, since zsh has a built-in `log` command that otherwise shadows
it. Routine messages are emitted at the `info` level; `--level debug` also
includes the verbose per-tick output (only produced when the daemon runs with
`--verbose`):

```
/usr/bin/log stream --predicate 'subsystem == "com.hmblair.wm"' --level info
```

To read past logs instead of streaming, swap `stream` for `show` and add a
window, e.g. `--last 5m --info`.

## Configuration

Configuration is read from `~/.config/wm/config.toml`. All fields are optional. The file is watched for changes and reloaded automatically.

```toml
# Gap in points between tiled windows and screen edges (default: 8)
gap = 8

# How often to poll for window changes, in Hz (default: 60)
poll_rate = 60

# Show clickable space indicators in the menu bar (default: true)
status_bar = true

# Draw an i3-style outline around the focused window (default: false)
focus_border = false

# Border color as a hex string (default: "#00ff00"), width in points
# (default: 1), and corner radius in points (default: 12). The color and
# width apply only when focus_border is true. On macOS Tahoe, wm pins the
# global window corner radius (NSConvolutionOverride1) to corner_radius so
# the outline always hugs the corners; apps pick up the new radius on their
# next launch. Reset it with: defaults delete -g NSConvolutionOverride1
border_color = "#00ff00"
border_width = 1
corner_radius = 12

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

### Focus border

When `focus_border` is enabled, a borderless click-through overlay draws an i3-style outline around the focused window, following it across tiling, focus changes, and Spaces. Since macOS exposes no per-window corner radius, wm pins the global window corner radius (`NSConvolutionOverride1`) to `corner_radius` so the outline matches every window's corners. Existing windows adopt a changed radius on their next launch.
