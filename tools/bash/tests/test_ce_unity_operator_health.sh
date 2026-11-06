#!/usr/bin/env bash
# RunTool_CeUnityOperator.sh の停滞時 health-check と exit code 分離の統合テスト

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WRAPPER="$PROJECT_ROOT/tools/bash/RunTool_CeUnityOperator.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ce-operator-health-test.XXXXXX")"
HELPER_PID=""

cleanup() {
  if [ -n "$HELPER_PID" ]; then
    taskkill //PID "$HELPER_PID" //T //F >/dev/null 2>&1 || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TEST_ROOT/status"

set +e
MISSING_ACTION_OUTPUT=$(bash "$WRAPPER" ping --root "$TEST_ROOT" --answer-modal 2>&1)
MISSING_ACTION_RC=$?
set -e
[ "$MISSING_ACTION_RC" -eq 4 ] || fail "answer-modal の値無しが拒否されない: rc=$MISSING_ACTION_RC output=$MISSING_ACTION_OUTPUT"

set +e
NO_CONFIRM_OUTPUT=$(bash "$WRAPPER" ping --root "$TEST_ROOT" --answer-modal discard 2>&1)
NO_CONFIRM_RC=$?
set -e
[ "$NO_CONFIRM_RC" -eq 4 ] || fail "discard の --confirm 不在が拒否されない: rc=$NO_CONFIRM_RC output=$NO_CONFIRM_OUTPUT"

set +e
CI_DISCARD_OUTPUT=$(CI=true bash "$WRAPPER" ping --root "$TEST_ROOT" --answer-modal discard --confirm 2>&1)
CI_DISCARD_RC=$?
set -e
[ "$CI_DISCARD_RC" -eq 4 ] || fail "CI の discard が拒否されない: rc=$CI_DISCARD_RC output=$CI_DISCARD_OUTPUT"

set +e
INVALID_ACTION_OUTPUT=$(bash "$WRAPPER" ping --root "$TEST_ROOT" --answer-modal unknown 2>&1)
INVALID_ACTION_RC=$?
set -e
[ "$INVALID_ACTION_RC" -eq 4 ] || fail "不正な answer-modal 値が拒否されない: rc=$INVALID_ACTION_RC output=$INVALID_ACTION_OUTPUT"

set +e
NOT_STARTED_OUTPUT=$(CE_OPERATOR_HEARTBEAT_STALE_SEC=0 bash "$WRAPPER" ping --root "$TEST_ROOT" 2>&1)
NOT_STARTED_RC=$?
set -e
[ "$NOT_STARTED_RC" -eq 3 ] || fail "未起動の exit code が $NOT_STARTED_RC: $NOT_STARTED_OUTPUT"

READY_FILE="$TEST_ROOT/helper.pid"
python - "$READY_FILE" <<'PY' &
import os
import sys
import time
from pathlib import Path

ready_path = Path(sys.argv[1])
ready_path.write_text(str(os.getpid()), encoding="ascii")
time.sleep(30)
PY
HELPER_PID=$!
for _ in $(seq 1 50); do
  [ -s "$READY_FILE" ] && break
  sleep 0.1
done
[ -s "$READY_FILE" ] || fail "heartbeat fixture process が起動しない"

HELPER_WINDOWS_PID=$(python - "$READY_FILE" <<'PY'
import sys
from pathlib import Path

print(Path(sys.argv[1]).read_text(encoding="ascii").strip())
PY
)

python - "$TEST_ROOT/status/heartbeat.json" "$HELPER_WINDOWS_PID" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

output_path, pid = sys.argv[1:3]
heartbeat = {
    "updated_at": (datetime.now(timezone.utc) - timedelta(seconds=60)).isoformat(),
    "pid": int(pid),
    "is_main_thread_blocking": False,
}
with open(output_path, "w", encoding="utf-8", newline="\n") as stream:
    json.dump(heartbeat, stream, ensure_ascii=False)
PY

set +e
FROZEN_OUTPUT=$(CE_OPERATOR_HEARTBEAT_STALE_SEC=0 bash "$WRAPPER" ping --root "$TEST_ROOT" 2>&1)
FROZEN_RC=$?
set -e
[ "$FROZEN_RC" -eq 6 ] || fail "モーダル未検出の exit code が $FROZEN_RC: $FROZEN_OUTPUT"
python - "$FROZEN_OUTPUT" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
assert result["status"] == "stalled"
health = result["error"]["health_check"]
assert health["status"] == "frozen"
assert health["modal"] is None
PY

set +e
ANSWER_NO_MODAL_OUTPUT=$(CE_OPERATOR_HEARTBEAT_STALE_SEC=0 CE_OPERATOR_ANSWER_MODAL_TIMEOUT_SEC=1 bash "$WRAPPER" ping --root "$TEST_ROOT" --answer-modal save 2>&1)
ANSWER_NO_MODAL_RC=$?
set -e
[ "$ANSWER_NO_MODAL_RC" -eq 6 ] || fail "モーダル無しの answer-modal が exit 6 にならない: rc=$ANSWER_NO_MODAL_RC output=$ANSWER_NO_MODAL_OUTPUT"

echo "OK: operator answer-modal policy and health-check exit codes"
