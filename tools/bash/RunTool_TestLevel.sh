#!/usr/bin/env bash
# 変更パスから回帰テストレベルと対象を選ぶ。
#
# 使い方:
#   RunTool_TestLevel.sh [--level diff|wide|full (旧称 Lv1|Lv2|Lv3)] [--base <git ref>] [--files <paths...>]
#                       [--plan] [--layer dotnet|editmode|playmode] [--coreclr-workers N]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY=""
for candidate in python python3; do
  if command -v "$candidate" >/dev/null 2>&1 \
    && "$candidate" -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "Python 3 が見つからない" >&2
  exit 3
fi

CE_BASH="$(command -v bash)"
if [ -z "$CE_BASH" ]; then
  echo "現在の Bash の実行パスを解決できない" >&2
  exit 3
fi

if command -v cygpath >/dev/null 2>&1; then
  WINDOWS_BASH_PATH="$(cygpath -a -w "$CE_BASH" 2>/dev/null || true)"
  if [ -n "$WINDOWS_BASH_PATH" ]; then
    CE_BASH="$WINDOWS_BASH_PATH"
  fi
fi

export CE_BASH
exec "$PY" "$SCRIPT_DIR/../python/ce_test_level.py" "$@"
