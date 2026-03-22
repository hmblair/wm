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
focus-follows-mouse
```

The process runs in the foreground. To launch it with [AeroSpace](https://github.com/nikitabobko/AeroSpace), add to `aerospace.toml`:

```toml
after-startup-command = [
    'exec-and-forget focus-follows-mouse',
]
```

## How it works

- **Mouse tracking**: A `CGEvent` tap listens for mouse movement events.
- **Window lookup**: `CGWindowListCopyWindowInfo` provides on-screen window positions via CoreGraphics (no accessibility overhead).
- **Focusing**: The Accessibility API (`AXUIElement`) raises and focuses the window under the cursor.
- **Keyboard-driven focus**: When an external focus change is detected after a keypress (e.g., a WM keybinding moved focus), the mouse is warped to the newly focused window.
