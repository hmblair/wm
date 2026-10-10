# wm

A lightweight macOS daemon that provides focus-follows-mouse behavior, a BSP tiling window manager, and a menu bar space indicator.

## Requirements

- macOS 14.4+
- Accessibility permissions (System Settings → Privacy & Security → Accessibility)

## Install

```
make install
wm start
```

This builds a release binary, installs it as an app bundle at `~/.local/wm.app`, symlinks the `wm` CLI into `~/.local/bin` (so `wm` works from the shell — ensure that directory is on your `PATH`), and registers it as a launchd service. The daemon itself applies its managed macOS settings — disabling built-in edge-drag tiling and automatic Space reordering, registering the Switch-to-Desktop shortcuts, and pinning the window corner radius — on start, and reverts them on stop (see [System settings](#system-settings)).

Override the install prefix with `PREFIX=/usr/local make install`.

To stop the service or remove it entirely:

```
wm stop        # stop the service
make uninstall # remove binary and plist
```

`make` is only needed to install. `swift build -c release` on its own produces a
working binary under `.build/`; it reports its version as `dev`, since the
version is stamped into the installed bundle's `Info.plist`.

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
| `dump` | Print on-screen window state and exit |
| `reset` | Revert wm-managed system settings to macOS defaults |
| `help` | Show usage |

| Flag | Description |
|------|-------------|
| `--version` | Print version and exit |

The `daemon` command additionally accepts:

| Flag | Description |
|------|-------------|
| `--verbose`, `-v` | Print timestamped debug output to stderr |
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

# Show the active Space in the menu bar with a dropdown of all Spaces (default: true)
status_bar = true

# Whether wm manages global macOS settings — native edge-drag tiling,
# automatic Space reordering, Switch-to-Desktop shortcuts, and the window
# corner radius — applying them on start and reverting on stop (default: true).
# Set false to leave the system untouched.
manage_system_settings = true

# Border color as a hex string (default: "#89f498"), width in points
# (default: 1), and corner radius in points (default: 12). The color and
# width apply only when the focus border is on. On macOS Tahoe, wm pins the
# global window corner radius (NSConvolutionOverride1) to corner_radius so
# the outline always hugs the corners; apps pick up the new radius on their
# next launch. wm reverts it on stop, or run `wm reset`.
border_color = "#89f498"
border_width = 1
corner_radius = 12

# Apps whose windows are completely invisible to the daemon.
# They won't be focused, tiled, or tracked in any way.
ignored_apps = ["borders", "Hammerspoon", "Alfred", "Raycast"]

# Apps that participate in focus-follows-mouse behavior but are excluded
# from tiling (their windows keep whatever size/position they have).
excluded_apps = ["Stickies"]

[features]
# Arrange windows in a BSP layout (default: true)
tiling = true

# Focus the window under the cursor (default: true)
focus_follows_mouse = true

# Draw an i3-style outline around the focused window (default: false)
focus_border = false

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

# Modifier for the system "Switch to Desktop N" shortcuts (Ctrl by default).
# wm registers these shortcuts and posts them to switch Spaces, so changing
# this re-registers them and updates wm's own key events, live on save.
[keybindings.space_switch_modifier]
ctrl = true
```

Each `[keybindings.*]` table is optional and merges over the defaults — an
omitted flag (or an omitted table) keeps its default value.

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

Tiling, focus follows mouse, and the focus border can each be turned on and off while the daemon runs. The `tiling`, `focus_follows_mouse`, and `focus_border` fields of the `[features]` config table set them at start. Saving a changed field applies it immediately. The Features submenu of the status bar dropdown toggles each one and saves the new value to the config file. The daemon rewrites the file to do so, which removes any comments in it. `wm` with no command reports which features are on.

### Focus follows mouse

A `CGEvent` tap tracks mouse movement. When the cursor enters a window, it is raised and focused via the Accessibility API. When the cursor moves to the desktop, focus is released to Finder.

### BSP tiling

Windows are arranged in a binary space partition (BSP) tree. New windows are inserted and the screen is recursively split. The layout respects window size constraints: windows with a minimum or maximum size (like System Settings or App Store) are detected reactively and the BSP split ratios are adjusted so constrained windows and their neighbors tile correctly.

Tiling is suspended during Mission Control and while the mouse button is held. The exception is a resize: dragging a window's edge or corner moves the split it shares with its neighbors, and the neighbors reflow as you drag.

### Status bar

The menu bar shows the active Space. Clicking it opens a dropdown that lists every desktop and full-screen app in Mission Control order. Each desktop shows its Switch-to-Desktop hotkey. A second line lists the apps with windows on the desktop, with the number of windows for any app that has more than one. The active Space is checked. Clicking a desktop in the list switches to it. Below the list, the Features submenu has a checked item for each feature that is on. Clicking an item toggles the feature.

### Keyboard navigation

Arrow-key bindings allow moving focus between windows, swapping window positions, rotating split orientation, and moving windows to other Spaces. The mouse is warped to the focused window after each action.

### Focus border

When the focus border is on, four borderless click-through overlay panels, one for each edge, draw an i3-style outline around the focused window, following it across tiling, focus changes, and Spaces. The outline is split across edge panels because Mission Control omits a window that another window covers completely. Since macOS exposes no per-window corner radius, wm pins the global window corner radius (`NSConvolutionOverride1`) to `corner_radius` so the outline matches every window's corners. Existing windows adopt a changed radius on their next launch.

### System settings

When `manage_system_settings` is enabled (the default), the daemon owns the global macOS settings it depends on rather than the installer: it disables native edge-drag tiling and automatic Space reordering, registers the Ctrl+1–9 (configurable) Switch-to-Desktop shortcuts, and pins the window corner radius. These are applied on start, re-applied idempotently on config reload (so the shortcut modifier and corner radius live-update), and reverted to macOS defaults on a clean stop.

Because a `SIGKILL` can't run the shutdown revert, `wm reset` reverts everything unconditionally; `make uninstall` calls it as a backstop.
