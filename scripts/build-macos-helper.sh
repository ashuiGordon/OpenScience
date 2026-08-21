#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER_OUTPUT="${OPENSCIENCE_HELPER_OUTPUT:-$PROJECT_ROOT/dist/macos-helper}"
HELPER_WORK="${OPENSCIENCE_HELPER_WORK:-$PROJECT_ROOT/build/macos-helper}"
HELPER_PYTHON="${OPENSCIENCE_HELPER_PYTHON:-3.11}"

mkdir -p "$HELPER_OUTPUT" "$HELPER_WORK/spec" "$HELPER_WORK/work"

cd "$PROJECT_ROOT"
uv run --python "$HELPER_PYTHON" --group desktop pyinstaller \
  --clean \
  --noconfirm \
  --onefile \
  --name openscience \
  --paths "$PROJECT_ROOT/src" \
  --distpath "$HELPER_OUTPUT" \
  --specpath "$HELPER_WORK/spec" \
  --workpath "$HELPER_WORK/work" \
  "$PROJECT_ROOT/packaging/macos/openscience_helper.py"

"$HELPER_OUTPUT/openscience" --version
"$HELPER_OUTPUT/openscience" providers --json >/dev/null
printf '%s\n' "$HELPER_OUTPUT/openscience"
