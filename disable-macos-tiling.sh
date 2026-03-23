#!/bin/bash
# Disable macOS built-in window tiling (requires logout to take effect)
defaults write -g EnableTilingByEdgeDrag -bool false
defaults write -g EnableTopTilingByEdgeDrag -bool false
defaults write -g EnableTilingOptionAccelerator -bool false
echo "macOS tiling disabled. Log out and back in for changes to take effect."
