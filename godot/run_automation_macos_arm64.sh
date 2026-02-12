#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_BIN_ARM64="$SCRIPT_DIR/engine-src/bin/godot.macos.editor.arm64"
ENGINE_BIN_X86_64="$SCRIPT_DIR/engine-src/bin/godot.macos.editor.x86_64"
ENGINE_BIN="$ENGINE_BIN_ARM64"
PROJECT_DIR="$SCRIPT_DIR/project"

HOSTPORT="${1:-127.0.0.1:24680}"
TOKEN="${2:-voxdebug}"
SCENE="${3:-res://scenes/TumblerTest.tscn}"

if [[ ! -x "$ENGINE_BIN" && -x "$ENGINE_BIN_X86_64" ]]; then
  ENGINE_BIN="$ENGINE_BIN_X86_64"
fi

if [[ ! -x "$ENGINE_BIN" ]]; then
  echo "error: missing engine binary: $ENGINE_BIN_ARM64 or $ENGINE_BIN_X86_64" >&2
  echo "build it first: $SCRIPT_DIR/build_editor_macos_arm64.sh" >&2
  exit 1
fi

exec "$ENGINE_BIN" \
  --path "$PROJECT_DIR" \
  --scene "$SCENE" \
  --automation "$HOSTPORT" \
  --automation-token "$TOKEN"
