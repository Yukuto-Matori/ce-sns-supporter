#!/usr/bin/env bash
# dotnet build ラッパ。出力を要約し、既知 warning を畳んで新規のものだけを見せる
#
# 使い方:
#   RunTool_DotnetBuild.sh <csproj|slnx> [--timeout 300] [--raw] [--warnings]
#   RunTool_DotnetBuild.sh <csproj|slnx> --update-baseline
#
#   --raw              要約せず MSBuild の生出力をそのまま出す
#   --warnings         既知 warning も個別に展開する (既定は件数だけに畳む)
#   --update-baseline  今回の warning 一覧で baseline を作り直す。
#                      以後のビルドではこれとの差分 (新規 warning) だけが出る
#
# 生出力は常に tmp/_build_last.txt へ残る。要約で足りないときはそれを読む
#
# exit code: 0 = 成功 / 1 = コンパイルエラー / 2 = timeout
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PY=""
for candidate in python python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >/dev/null 2>&1; then
    PY="$candidate"; break
  fi
done
if [ -z "$PY" ]; then
  echo "Python 3 が見つからない" >&2
  exit 3
fi

if [ $# -lt 1 ]; then
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 4
fi

TARGET="$1"; shift
TIMEOUT_SEC=300
RAW=0
DIGEST_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
    --raw) RAW=1; shift ;;
    --warnings) DIGEST_ARGS+=(--max-warnings 200); shift ;;
    --update-baseline) DIGEST_ARGS+=(--update-baseline); shift ;;
    *) echo "不明な引数: $1" >&2; exit 4 ;;
  esac
done

cd "$PROJECT_ROOT" || exit 4

LOG_PATH="tmp/_build_last.txt"
mkdir -p tmp

RESTORE_STATUS=$(PYTHONIOENCODING=UTF-8 "$PY" -c '
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from ce_test_level import dotnet_restore_required
print("required" if dotnet_restore_required(sys.argv[3], Path(sys.argv[2])) else "skipped")
' "$PROJECT_ROOT/tools/python" "$PROJECT_ROOT" "$TARGET" 2>&1)
RESTORE_CHECK_RC=$?
if [ "$RESTORE_CHECK_RC" -ne 0 ]; then
  echo "restore 判定に失敗: $RESTORE_STATUS" >&2
  exit 3
fi

DOTNET_ARGS=(build "$TARGET" -v:q)
if [ "$RESTORE_STATUS" = "skipped" ]; then
  DOTNET_ARGS+=(--no-restore)
  RESTORE_SUMMARY="restore=skipped (project.assets.json is newer than each csproj)"
else
  RESTORE_SUMMARY="restore=performed (assets missing, stale, or target not recognized)"
fi

timeout "$TIMEOUT_SEC" dotnet "${DOTNET_ARGS[@]}" > "$LOG_PATH" 2>&1
RC=$?
if [ "$RC" = "0" ] && [ "$RESTORE_STATUS" = "required" ]; then
  ASSET_MARK_OUTPUT=$(PYTHONIOENCODING=UTF-8 "$PY" -c '
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from ce_test_level import dotnet_mark_assets_current
dotnet_mark_assets_current(sys.argv[3], Path(sys.argv[2]))
' "$PROJECT_ROOT/tools/python" "$PROJECT_ROOT" "$TARGET" 2>&1)
  ASSET_MARK_RC=$?
  if [ "$ASSET_MARK_RC" -ne 0 ]; then
    echo "restore 後の assets 更新に失敗: $ASSET_MARK_OUTPUT" >&2
    RC=1
  fi
fi
echo "$RESTORE_SUMMARY"

if [ "$RC" = "124" ]; then
  echo "BUILD timeout  ${TIMEOUT_SEC}s を超過した"
  echo "  full: $LOG_PATH"
  exit 2
fi

if [ "$RAW" = "1" ]; then
  cat "$LOG_PATH"
  exit $RC
fi

"$PY" "$SCRIPT_DIR/../python/ce_output_digest.py" dotnet \
  --input "$LOG_PATH" --tee "$LOG_PATH" ${DIGEST_ARGS[@]+"${DIGEST_ARGS[@]}"}
DIGEST_RC=$?

# dotnet 自体が失敗していれば、要約側が error を拾えなくてもその結果を優先する
if [ "$RC" != "0" ]; then
  exit 1
fi
exit $DIGEST_RC
