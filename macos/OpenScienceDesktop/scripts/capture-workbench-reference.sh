#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPOSITORY_DIR=$(CDPATH= cd -- "$PROJECT_DIR/../.." && pwd)
APP_PATH=${OPENSCIENCE_CAPTURE_APP_PATH:-"$PROJECT_DIR/dist/OpenScience.app"}
OUTPUT_PATH=${1:-"$REPOSITORY_DIR/design/conversation-workbench/implementation-option-3.png"}
RAW_PATH="${OUTPUT_PATH%.png}-raw.png"

case "$OUTPUT_PATH" in
    /*.png) ;;
    *)
        echo "Capture output must be an absolute PNG path: $OUTPUT_PATH" >&2
        exit 2
        ;;
esac

if [ ! -x "$APP_PATH/Contents/MacOS/OpenScienceDesktop" ]; then
    echo "Built app not found at $APP_PATH" >&2
    echo "Run $SCRIPT_DIR/build-app.sh first or set OPENSCIENCE_CAPTURE_APP_PATH." >&2
    exit 2
fi

mkdir -p "$(dirname -- "$OUTPUT_PATH")"

APP_PID=$(swift -e '
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(2) }
let applicationURL = URL(fileURLWithPath: CommandLine.arguments[1])
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
configuration.createsNewApplicationInstance = true
configuration.arguments = ["--design-preview"]
NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) {
    application, error in
    if let error {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(3)
    }
    guard let application else { exit(3) }
    print(application.processIdentifier)
    exit(0)
}
RunLoop.main.run()
' "$APP_PATH")

cleanup() {
    if kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f -- "$RAW_PATH"
}
trap cleanup EXIT HUP INT TERM

swift -e '
import AppKit

guard CommandLine.arguments.count == 2,
      let requestedPID = Int32(CommandLine.arguments[1]),
      let application = NSRunningApplication(processIdentifier: requestedPID) else {
    exit(2)
}

for _ in 0..<100 where !application.isFinishedLaunching {
    Thread.sleep(forTimeInterval: 0.05)
}
guard application.isFinishedLaunching else { exit(3) }
let target = NSAppleEventDescriptor(processIdentifier: requestedPID)
let reopen = NSAppleEventDescriptor(
    eventClass: AEEventClass(kCoreEventClass),
    eventID: AEEventID(kAEReopenApplication),
    targetDescriptor: target,
    returnID: AEReturnID(kAutoGenerateReturnID),
    transactionID: AETransactionID(kAnyTransactionID)
)
do { _ = try reopen.sendEvent(options: [.noReply], timeout: 2) } catch { exit(3) }
_ = application.activate(options: [.activateAllWindows])
' "$APP_PID"

WINDOW_INFO=$(swift -e '
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2,
      let requestedPID = Int32(CommandLine.arguments[1]) else {
    exit(2)
}

for _ in 0..<120 {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    if let window = windows.first(where: { entry in
        guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
              ownerPID == Int(requestedPID),
              let layer = entry[kCGWindowLayer as String] as? Int,
              layer == 0,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else {
            return false
        }
        return width > 1_000 && height > 700
    }), let number = window[kCGWindowNumber as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double,
        let height = bounds["Height"] as? Double
    {
        print("\(number)\t\(Int(width.rounded()))\t\(Int(height.rounded()))")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}

exit(3)
' "$APP_PID")

set -- $WINDOW_INFO
WINDOW_ID=$1
WINDOW_POINTS_WIDTH=$2
WINDOW_POINTS_HEIGHT=$3

# Give SwiftUI one final layout pass after the deterministic window reaches its target size.
sleep 1
screencapture -x -l "$WINDOW_ID" "$RAW_PATH"

RAW_WIDTH=$(sips -g pixelWidth "$RAW_PATH" | awk '/pixelWidth/ { print $2 }')
RAW_HEIGHT=$(sips -g pixelHeight "$RAW_PATH" | awk '/pixelHeight/ { print $2 }')

# Normalize Retina density to the actual logical window size without changing its aspect ratio.
# A display that cannot present the 1487x1058 reference must remain visibly smaller; stretching
# that capture would make the design comparison invalid.
sips --resampleHeightWidth "$WINDOW_POINTS_HEIGHT" "$WINDOW_POINTS_WIDTH" \
    "$RAW_PATH" --out "$OUTPUT_PATH" >/dev/null
echo "Captured window $WINDOW_ID from PID $APP_PID"
echo "Raw pixels: ${RAW_WIDTH}x${RAW_HEIGHT}; logical window: ${WINDOW_POINTS_WIDTH}x${WINDOW_POINTS_HEIGHT}"
if [ "$WINDOW_POINTS_WIDTH" -ne 1487 ] || [ "$WINDOW_POINTS_HEIGHT" -ne 1058 ]; then
    echo "Warning: the active display constrained the requested 1487x1058 reference window." >&2
    if [ "${OPENSCIENCE_STRICT_CAPTURE_SIZE:-0}" = 1 ]; then
        exit 4
    fi
fi
echo "$OUTPUT_PATH"
