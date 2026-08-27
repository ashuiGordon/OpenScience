#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPOSITORY_DIR=$(CDPATH= cd -- "$PROJECT_DIR/../.." && pwd)
SOURCE_PATH=${1:-"$REPOSITORY_DIR/design/conversation-workbench/selected-option-3.png"}
IMPLEMENTATION_PATH=${2:-"$REPOSITORY_DIR/design/conversation-workbench/implementation-option-3.png"}
COMPARISON_PATH=${3:-"$REPOSITORY_DIR/design/conversation-workbench/qa-comparison.png"}
MASK_PATH=${4:-${OPENSCIENCE_COMPARISON_MASK:-}}
TARGET_WIDTH=1487
TARGET_HEIGHT=1058
MINIMUM_SCORE=0.90

for INPUT_PATH in "$SOURCE_PATH" "$IMPLEMENTATION_PATH"; do
    if [ ! -f "$INPUT_PATH" ]; then
        echo "Missing comparison input: $INPUT_PATH" >&2
        exit 2
    fi
done

for TOOL in ffmpeg ffprobe; do
    if ! command -v "$TOOL" >/dev/null 2>&1; then
        echo "Required visual comparison tool is unavailable: $TOOL" >&2
        exit 2
    fi
done

dimensions() {
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -of csv=s=x:p=0 "$1"
}

SOURCE_DIMENSIONS=$(dimensions "$SOURCE_PATH")
IMPLEMENTATION_DIMENSIONS=$(dimensions "$IMPLEMENTATION_PATH")
EXPECTED_DIMENSIONS="${TARGET_WIDTH}x${TARGET_HEIGHT}"
if [ "$SOURCE_DIMENSIONS" != "$EXPECTED_DIMENSIONS" ] || \
    [ "$IMPLEMENTATION_DIMENSIONS" != "$EXPECTED_DIMENSIONS" ]; then
    echo "Comparison inputs must both be ${EXPECTED_DIMENSIONS}; got source=${SOURCE_DIMENSIONS}, implementation=${IMPLEMENTATION_DIMENSIONS}." >&2
    exit 2
fi

mkdir -p "$(dirname -- "$COMPARISON_PATH")"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openscience-visual-compare.XXXXXX")
cleanup() {
    rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM
STATS_PATH="$TEMP_DIR/ssim.log"

if [ -n "$MASK_PATH" ]; then
    if [ ! -f "$MASK_PATH" ]; then
        echo "Missing comparison mask: $MASK_PATH" >&2
        exit 2
    fi
    MASK_DIMENSIONS=$(dimensions "$MASK_PATH")
    if [ "$MASK_DIMENSIONS" != "$EXPECTED_DIMENSIONS" ]; then
        echo "Mask must be ${EXPECTED_DIMENSIONS}; got ${MASK_DIMENSIONS}." >&2
        exit 2
    fi
    MASK_BINARY_ERROR=$(ffmpeg -hide_banner -loglevel error -i "$MASK_PATH" \
        -filter_complex \
        "[0:v]scale=in_range=auto:out_range=full,format=gray,split[original][copy];[copy]lut=y='if(gte(val,128),255,0)'[binary];[original][binary]blend=all_mode=difference,signalstats,metadata=print:file=-" \
        -frames:v 1 -f null - 2>&1 \
        | awk -F= '/lavfi.signalstats.YMAX/ { print $2; exit }')
    if [ -z "$MASK_BINARY_ERROR" ] || \
        ! awk -v error="$MASK_BINARY_ERROR" 'BEGIN { exit !(error <= 3) }'; then
        echo "Mask must be binary black/white; partial-opacity masking is rejected." >&2
        exit 2
    fi
    MASK_AVERAGE=$(ffmpeg -hide_banner -loglevel error -i "$MASK_PATH" \
        -vf "scale=in_range=auto:out_range=full,format=gray,signalstats,metadata=print:file=-" -frames:v 1 -f null - 2>&1 \
        | awk -F= '/lavfi.signalstats.YAVG/ { print $2; exit }')
    if [ -z "$MASK_AVERAGE" ]; then
        echo "Could not measure comparison mask coverage." >&2
        exit 2
    fi
    if ! awk -v average="$MASK_AVERAGE" 'BEGIN { exit !((average / 255.0) <= 0.01) }'; then
        echo "Mask coverage exceeds the 1% anti-gaming ceiling." >&2
        exit 2
    fi
    ffmpeg -hide_banner -loglevel error -y \
        -i "$SOURCE_PATH" -i "$IMPLEMENTATION_PATH" -i "$MASK_PATH" \
        -filter_complex \
        "[0:v]format=rgb24[source];[1:v]format=rgb24[actual];[2:v]scale=in_range=auto:out_range=full,format=gray[mask];[actual][source][mask]maskedmerge[masked];[source][masked]ssim=stats_file=$STATS_PATH[scored]" \
        -map "[scored]" -frames:v 1 -f null -
else
    ffmpeg -hide_banner -loglevel error -y \
        -i "$SOURCE_PATH" -i "$IMPLEMENTATION_PATH" \
        -filter_complex \
        "[0:v]format=rgb24[source];[1:v]format=rgb24[actual];[source][actual]ssim=stats_file=$STATS_PATH[scored]" \
        -map "[scored]" -frames:v 1 -f null -
fi

SCORE=$(awk -F'All:' '/All:/ { split($2, fields, " "); print fields[1]; exit }' "$STATS_PATH")
if [ -z "$SCORE" ]; then
    echo "SSIM comparison did not produce a score." >&2
    exit 2
fi

ffmpeg -hide_banner -loglevel error -y \
    -i "$SOURCE_PATH" -i "$IMPLEMENTATION_PATH" \
    -filter_complex \
    "[0:v]format=rgb24[source];[1:v]format=rgb24[implementation];[source][implementation]hstack=inputs=2" \
    -frames:v 1 "$COMPARISON_PATH"

echo "SSIM score: $SCORE (required: >= $MINIMUM_SCORE)"
echo "$COMPARISON_PATH"

if ! awk -v score="$SCORE" -v minimum="$MINIMUM_SCORE" \
    'BEGIN { exit !(score + 0 >= minimum + 0) }'; then
    echo "Visual comparison failed: score $SCORE is below $MINIMUM_SCORE." >&2
    exit 1
fi
