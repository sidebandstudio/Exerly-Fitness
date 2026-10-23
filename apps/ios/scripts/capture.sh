#!/usr/bin/env bash
# Runs UI tests against an isolated fixture API and writes their captures as PNGs.
#
#   SIM=<simulator udid> PORT=<fixture port> OUT=<dir> apps/ios/scripts/capture.sh <test> [<test> ...]
#
# <test> is e.g. ExerlyUITests/TodayUITests/testTodayCapture. Optional:
#   APPEARANCE=dark|light   LARGEST_TYPE=1   BUILD=1 (build for testing first)
#   CAPTURE=0 runs tests without the opt-in capture tests, as a regression run.
# The fixture on PORT must already be running:
#   EXERLY_FIXTURE_PORT=<port> node scripts/ios-fixture-api.cjs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.2.app/Contents/Developer}"
: "${SIM:?Set SIM to a simulator udid}" "${PORT:?Set PORT to the fixture port}" "${OUT:?Set OUT to a directory}"
[[ "$#" -gt 0 ]] || { echo 'Name at least one test' >&2; exit 2; }
curl -fsS --max-time 2 "http://127.0.0.1:$PORT/__test/ready" >/dev/null || { echo "No fixture on $PORT" >&2; exit 2; }
mkdir -p "$OUT"
args=(-project "$ROOT/apps/ios/Exerly.xcodeproj" -scheme Exerly -derivedDataPath "$ROOT/.deriveddata"
  -destination "platform=iOS Simulator,id=$SIM" CODE_SIGN_IDENTITY=-)
if [[ "${BUILD:-0}" == 1 ]]; then
  xcodebuild "${args[@]}" build-for-testing > "$OUT/build.log" 2>&1 || { grep -E 'error:' "$OUT/build.log" | head -20; exit 1; }
fi
only=(); for test in "$@"; do only+=("-only-testing:$test"); done
result="$OUT/run-$(date +%s).xcresult"
status=0
TEST_RUNNER_EXERLY_DESIGN_CAPTURE="${CAPTURE:-1}" TEST_RUNNER_EXERLY_UI_FIXTURE_URL="http://127.0.0.1:$PORT" \
TEST_RUNNER_EXERLY_SCREEN_DIR="$OUT" TEST_RUNNER_EXERLY_TEST_APPEARANCE="${APPEARANCE:-dark}" \
TEST_RUNNER_EXERLY_TEST_LARGEST_TYPE="${LARGEST_TYPE:-0}" \
  xcodebuild "${args[@]}" -resultBundlePath "$result" "${only[@]}" test-without-building > "$OUT/test.log" 2>&1 || status=$?
# The summary never decides the exit status: a long one or an empty one is still the tests' result.
grep -m 40 -E "Test Case .*(passed|failed)|error:|XCTAssert" "$OUT/test.log" || true
exit $status
