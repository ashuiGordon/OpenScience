#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
OUTPUT_DIR=${OUTPUT_DIR:-"$PROJECT_DIR/dist"}
APP_PATH="$OUTPUT_DIR/OpenScience.app"

case "$APP_PATH" in
    /*/OpenScience.app) ;;
    *)
        echo "Refusing unsafe app output path: $APP_PATH" >&2
        exit 2
        ;;
esac

cd "$PROJECT_DIR"
swift build -c "$CONFIGURATION" --product OpenScienceDesktop
BIN_DIR=$(swift build -c "$CONFIGURATION" --show-bin-path)

if [ -e "$APP_PATH" ]; then
    rm -rf -- "$APP_PATH"
fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/OpenScienceDesktop" "$APP_PATH/Contents/MacOS/OpenScienceDesktop"
cp "$PROJECT_DIR/App/Info.plist" "$APP_PATH/Contents/Info.plist"
chmod 755 "$APP_PATH/Contents/MacOS/OpenScienceDesktop"

RESOURCE_SOURCE="$PROJECT_DIR/Sources/OpenScienceDesktop/Resources"
if [ -d "$RESOURCE_SOURCE" ]; then
    cp -R "$RESOURCE_SOURCE/." "$APP_PATH/Contents/Resources/"
fi

if [ -n "${OPENSCIENCE_HELPER_PATH:-}" ]; then
    if [ ! -f "$OPENSCIENCE_HELPER_PATH" ] || [ ! -x "$OPENSCIENCE_HELPER_PATH" ]; then
        echo "OPENSCIENCE_HELPER_PATH must point to an executable standalone helper" >&2
        exit 2
    fi
    mkdir -p "$APP_PATH/Contents/Helpers"
    cp "$OPENSCIENCE_HELPER_PATH" "$APP_PATH/Contents/Helpers/openscience"
    chmod 755 "$APP_PATH/Contents/Helpers/openscience"
fi

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_PATH"
fi

echo "$APP_PATH"
