#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$SCRIPT_DIR/engine-src"

if ! command -v scons >/dev/null 2>&1; then
  echo "error: scons not found. Install it (e.g. brew install scons)." >&2
  exit 1
fi

# Godot's macOS Vulkan backend (MoltenVK) expects a LunarG Vulkan SDK install.
if ! compgen -G "$HOME/VulkanSDK/*/setup-env.sh" >/dev/null; then
  echo "Vulkan SDK not found under ~/VulkanSDK. Installing via engine script..." >&2
  (cd "$ENGINE_DIR" && sh misc/scripts/install_vulkan_sdk_macos.sh)
fi

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"

cd "$ENGINE_DIR"
scons -Q platform=macos arch=arm64 target=editor -j"$JOBS" module_voxels_enabled=yes

echo
echo "Built: $ENGINE_DIR/bin/godot.macos.editor.arm64"
