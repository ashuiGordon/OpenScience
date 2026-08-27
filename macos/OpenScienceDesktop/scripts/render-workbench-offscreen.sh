#!/bin/zsh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_PATH=${1:-"$PROJECT_DIR/.build/workbench-option-3-offscreen.png"}

case "$OUTPUT_PATH" in
    /*.png) ;;
    *)
        echo "Render output must be an absolute PNG path: $OUTPUT_PATH" >&2
        exit 2
        ;;
esac

cd "$PROJECT_DIR"
swift build --disable-sandbox -Xswiftc -warnings-as-errors >/dev/null
BIN_DIR=$(swift build --show-bin-path)
MODULE_DIR="$BIN_DIR/Modules"
RENDER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openscience-preview.XXXXXX")
RENDERER_PATH="$RENDER_DIR/openscience-preview-renderer"
RAW_PATH="$RENDER_DIR/workbench-2x.png"

cleanup() {
    rm -rf -- "$RENDER_DIR"
}
trap cleanup EXIT HUP INT TERM

ui_sources=(${(f)"$(rg --files Sources/OpenScienceDesktop | rg '\.swift$' | rg -v '/Logic/|OpenScienceDesktopApp\.swift$')"})
core_objects=("$BIN_DIR/OpenScienceCore.build"/*.o)
logic_objects=("$BIN_DIR/OpenScienceDesktopLogic.build"/*.o)

swiftc -parse-as-library -module-name OpenSciencePreviewRenderer \
    -I "$MODULE_DIR" \
    "${ui_sources[@]}" "$SCRIPT_DIR/WorkbenchPreviewRenderer.swift" \
    "${core_objects[@]}" "${logic_objects[@]}" \
    -framework Security -o "$RENDERER_PATH"

mkdir -p "$(dirname -- "$OUTPUT_PATH")"
"$RENDERER_PATH" --design-preview "$RAW_PATH"
sips --resampleHeightWidth 1058 1487 "$RAW_PATH" --out "$OUTPUT_PATH" >/dev/null
echo "$OUTPUT_PATH"
