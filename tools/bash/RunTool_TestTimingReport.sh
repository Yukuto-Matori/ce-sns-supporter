#!/usr/bin/env bash
# 直近のテスト実行時間と予算超過を Markdown レポートへまとめる
#
# 使い方:
#   RunTool_TestTimingReport.sh [--last N] [--kind editmode|playmode|coreclr] [--top 20]
#       [--import-existing] [--digest]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PY=""
for candidate in python python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "Python 3 が見つからない" >&2
  exit 3
fi

cd "$PROJECT_ROOT" || exit 4
exec "$PY" "$SCRIPT_DIR/../python/ce_test_timing.py" report \
  --root "$PROJECT_ROOT/tmp/test_timing" "$@"
