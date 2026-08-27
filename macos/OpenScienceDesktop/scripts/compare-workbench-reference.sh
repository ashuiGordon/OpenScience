#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPOSITORY_DIR=$(CDPATH= cd -- "$PROJECT_DIR/../.." && pwd)
SOURCE_PATH=${1:-"$REPOSITORY_DIR/design/conversation-workbench/selected-option-3.png"}
IMPLEMENTATION_PATH=${2:-"$REPOSITORY_DIR/design/conversation-workbench/implementation-option-3.png"}
COMPARISON_PATH=${3:-"$REPOSITORY_DIR/design/conversation-workbench/qa-comparison.png"}

for INPUT_PATH in "$SOURCE_PATH" "$IMPLEMENTATION_PATH"; do
    if [ ! -f "$INPUT_PATH" ]; then
        echo "Missing comparison input: $INPUT_PATH" >&2
        exit 2
    fi
done

mkdir -p "$(dirname -- "$COMPARISON_PATH")"

ffmpeg -hide_banner -loglevel error -y \
    -i "$SOURCE_PATH" \
    -i "$IMPLEMENTATION_PATH" \
    -filter_complex \
    "[0:v]scale=1487:1058:flags=lanczos,format=rgb24[source];[1:v]scale=1487:-2:flags=lanczos,crop=1487:min(ih\\,1058):0:0,pad=1487:1058:0:0:color=0x111317,format=rgb24[implementation];[source][implementation]hstack=inputs=2" \
    -frames:v 1 "$COMPARISON_PATH"

echo "$COMPARISON_PATH"
