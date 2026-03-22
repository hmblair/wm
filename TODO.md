# TODO

## Mouse warp uses stale window positions during layout transitions

When an external focus change triggers a mouse warp (e.g., opening a new
window with Cmd+N), the warp may land at the wrong position. This happens
because Aerospace repositions and resizes windows after changing focus, but
the AX position query in `checkExternalFocusChange` reads the window's
frame before the layout has settled.

**Reproduction:** On a workspace with two tiled windows, open a new window
(Cmd+N in Firefox). The mouse warps to the new window's pre-rearrangement
position instead of its final tiled position.

**Likely fix:** After warping, schedule a follow-up check ~200ms later that
re-reads the focused window's position and corrects the warp if it moved.
