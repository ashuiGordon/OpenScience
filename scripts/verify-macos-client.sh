#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT_PACKAGE="$PROJECT_ROOT/macos/OpenScienceDesktop"
FIXTURE="$PROJECT_ROOT/examples/corpus.json"
VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openscience-macos-verify.XXXXXX")"

cleanup() {
  rm -rf -- "$VERIFY_ROOT"
}
trap cleanup EXIT

section() {
  printf '\n==> %s\n' "$1"
}

pass() {
  printf 'PASS: %s\n' "$1"
}

skip() {
  printf 'SKIP: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

assert_one_json_object() {
  local path="$1"
  uv run python - "$path" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = text.splitlines()
if len(lines) != 1:
    raise SystemExit(f"{path}: expected exactly one JSON line, got {len(lines)}")
value = json.loads(lines[0])
if not isinstance(value, dict):
    raise SystemExit(f"{path}: expected a JSON object")
PY
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "macOS verification requires Darwin"
fi

for command in uv swift xcode-select plutil codesign env; do
  require_command "$command"
done

cd "$PROJECT_ROOT"

section "Python quality gates"
uv sync --frozen --all-groups
uv run ruff format --check .
uv run ruff check .
uv run mypy src
uv run pytest
pass "Python formatting, lint, typing, and deterministic tests"

section "Swift formatting and build"
(
  cd "$SWIFT_PACKAGE"
  swift format lint --recursive --strict Sources Tests Package.swift
  swift build -c release --product OpenScienceDesktop
)
pass "Swift formatting and release build"

section "Swift test discovery"
SWIFT_TEST_LIST="$VERIFY_ROOT/swift-tests.txt"
SWIFT_TEST_LIST_ERRORS="$VERIFY_ROOT/swift-tests.err"
if (
  cd "$SWIFT_PACKAGE"
  swift test list >"$SWIFT_TEST_LIST" 2>"$SWIFT_TEST_LIST_ERRORS"
); then
  :
elif (
  cd "$SWIFT_PACKAGE"
  swift test --list-tests >"$SWIFT_TEST_LIST" 2>"$SWIFT_TEST_LIST_ERRORS"
); then
  :
else
  sed -n '1,120p' "$SWIFT_TEST_LIST_ERRORS" >&2
  fail "SwiftPM could not discover tests"
fi

SWIFT_TEST_COUNT="$(grep -Ec '^[^[:space:]]+/[^[:space:]]+$' "$SWIFT_TEST_LIST" || true)"
DEVELOPER_DIRECTORY="$(xcode-select -p)"
FULL_XCODE=false
if [[ "$DEVELOPER_DIRECTORY" == *.app/Contents/Developer* ]]; then
  FULL_XCODE=true
fi

if [[ "$SWIFT_TEST_COUNT" -eq 0 ]]; then
  if [[ -n "${CI:-}" || "$FULL_XCODE" == "true" ]]; then
    fail "full-Xcode/CI verification discovered zero Swift tests"
  fi
  skip "Command Line Tools has no discoverable XCTest runtime; Swift tests were not reported as passing"
else
  OPENSCIENCE_E2E_CLI="$PROJECT_ROOT/.venv/bin/openscience" \
    OPENSCIENCE_E2E_FIXTURE="$FIXTURE" \
    swift test --package-path "$SWIFT_PACKAGE"
  pass "$SWIFT_TEST_COUNT Swift tests discovered and executed"
fi

section "Standalone engine helper"
HELPER_OUTPUT="$VERIFY_ROOT/helper"
HELPER_WORK="$VERIFY_ROOT/helper-work"
OPENSCIENCE_HELPER_OUTPUT="$HELPER_OUTPUT" \
  OPENSCIENCE_HELPER_WORK="$HELPER_WORK" \
  "$PROJECT_ROOT/scripts/build-macos-helper.sh"
HELPER="$HELPER_OUTPUT/openscience"
[[ -x "$HELPER" ]] || fail "standalone helper was not produced"
"$HELPER" --version | grep -Eq '^openscience [0-9]+\.[0-9]+\.[0-9]+$'
pass "standalone helper built and version probe succeeded"

section "Self-contained app assembly"
APP_OUTPUT="$VERIFY_ROOT/app"
OUTPUT_DIR="$APP_OUTPUT" \
  CONFIGURATION=release \
  OPENSCIENCE_HELPER_PATH="$HELPER" \
  "$SWIFT_PACKAGE/scripts/build-app.sh"
APP="$APP_OUTPUT/OpenScience.app"
APP_EXECUTABLE="$APP/Contents/MacOS/OpenScienceDesktop"
APP_HELPER="$APP/Contents/Helpers/openscience"
[[ -x "$APP_EXECUTABLE" ]] || fail "app executable is missing"
[[ -x "$APP_HELPER" ]] || fail "bundled helper is missing"
plutil -lint "$APP/Contents/Info.plist"
[[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist")" == "14.0" ]] \
  || fail "LSMinimumSystemVersion is not 14.0"
codesign --verify --deep --strict --verbose=2 "$APP"
pass "app structure, metadata, bundled helper, and local ad hoc seal verified"

section "Real offline helper journey"
JOURNEY="$VERIFY_ROOT/journey"
WORKSPACE="$JOURNEY/task-workspace"
PLAN="$JOURNEY/reviewed-plan.json"
BUNDLE="$JOURNEY/research-bundle.zip"
mkdir -p "$JOURNEY"

BASE_JOURNEY_ENV=(
  env -i
  "PATH=$PATH"
  "HOME=$HOME"
  "TMPDIR=${TMPDIR:-/tmp}"
  "LANG=${LANG:-C.UTF-8}"
)
CREDENTIAL_JOURNEY_ENV=(
  "${BASE_JOURNEY_ENV[@]}"
  "OPENSCIENCE_OPENALEX_API_KEY=desktop-openalex-canary-260331d9"
  "OPENSCIENCE_CROSSREF_API_KEY=desktop-crossref-canary-968a0c93"
  "OPENSCIENCE_MODEL_API_KEY=desktop-model-canary-125416cd"
  "AWS_SECRET_ACCESS_KEY=desktop-unrelated-canary-40e819c0"
)

QUESTION="What practices make computational studies easier to reproduce?"
"${BASE_JOURNEY_ENV[@]}" "$APP_HELPER" plan \
  --json \
  --output "$PLAN" \
  --workspace "$WORKSPACE" \
  --max-records 50 \
  --max-network-requests 0 \
  --timeout 30 \
  -- "$QUESTION" >"$JOURNEY/plan.json"
assert_one_json_object "$JOURNEY/plan.json"

"${CREDENTIAL_JOURNEY_ENV[@]}" "$APP_HELPER" run \
  --json \
  --yes \
  --plan "$PLAN" \
  --fixture "$FIXTURE" \
  --workspace "$WORKSPACE" \
  --max-records 50 \
  --max-network-requests 0 \
  --timeout 30 \
  --synthesizer extractive \
  -- "$QUESTION" >"$JOURNEY/run.json"
assert_one_json_object "$JOURNEY/run.json"

RUN_DIRECTORY="$(uv run python - "$JOURNEY/run.json" "$WORKSPACE" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
workspace = Path(sys.argv[2]).resolve()
run_directory = Path(payload["run_directory"]).resolve()
if payload.get("status") != "completed":
    raise SystemExit(f"offline run did not complete: {payload.get('status')}")
if run_directory.parent != workspace:
    raise SystemExit("run directory escaped the task workspace")
print(run_directory)
PY
)"

"${BASE_JOURNEY_ENV[@]}" "$APP_HELPER" validate \
  "$RUN_DIRECTORY" --json >"$JOURNEY/validate.json"
assert_one_json_object "$JOURNEY/validate.json"
"${BASE_JOURNEY_ENV[@]}" "$APP_HELPER" inspect \
  "$RUN_DIRECTORY" --json >"$JOURNEY/inspect.json"
assert_one_json_object "$JOURNEY/inspect.json"
"${BASE_JOURNEY_ENV[@]}" "$APP_HELPER" replay \
  "$RUN_DIRECTORY" --json >"$JOURNEY/replay.json"
assert_one_json_object "$JOURNEY/replay.json"
"${BASE_JOURNEY_ENV[@]}" "$APP_HELPER" export \
  "$RUN_DIRECTORY" --output "$BUNDLE" --json >"$JOURNEY/export.json"
assert_one_json_object "$JOURNEY/export.json"

uv run python - "$RUN_DIRECTORY" "$BUNDLE" <<'PY'
from __future__ import annotations

import sys
import zipfile
from pathlib import Path

from openscience_agent.export import validate_export_bundle
from openscience_agent.validation import validate_run

run_directory = Path(sys.argv[1])
bundle = Path(sys.argv[2])
canaries = tuple(
    value.encode()
    for value in (
        "desktop-openalex-canary-260331d9",
        "desktop-crossref-canary-968a0c93",
        "desktop-model-canary-125416cd",
        "desktop-unrelated-canary-40e819c0",
    )
)

if not validate_run(run_directory).valid:
    raise SystemExit("offline run failed validation")
if not validate_export_bundle(bundle).valid:
    raise SystemExit("exported bundle failed offline validation")

for path in run_directory.rglob("*"):
    if path.is_file():
        contents = path.read_bytes()
        if any(canary in contents for canary in canaries):
            raise SystemExit(f"secret canary found in run artifact: {path.name}")

with zipfile.ZipFile(bundle) as archive:
    for name in archive.namelist():
        contents = archive.read(name)
        if any(canary in contents for canary in canaries):
            raise SystemExit(f"secret canary found in export entry: {name}")
PY
pass "plan, run, validate, inspect, replay, export, and canary checks"

printf '\nmacOS client verification completed.\n'
printf 'Distribution boundary: local ad hoc sealing only; sandboxing, Developer ID signing, and notarization were not verified.\n'
