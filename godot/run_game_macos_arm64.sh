#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_BIN="$SCRIPT_DIR/engine-src/bin/godot.macos.editor.arm64"
PROJECT_DIR="$SCRIPT_DIR/project"

if [[ ! -x "$ENGINE_BIN" ]]; then
  echo "error: missing engine binary: $ENGINE_BIN" >&2
  echo "build it first: $SCRIPT_DIR/build_editor_macos_arm64.sh" >&2
  exit 1
fi

exec "$ENGINE_BIN" --path "$PROJECT_DIR"
