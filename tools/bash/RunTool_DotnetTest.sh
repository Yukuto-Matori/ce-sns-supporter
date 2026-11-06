#!/usr/bin/env bash
# CoreCLR test wrapper. TRX を保存し、共通の実行時間履歴へ記録する
#
# 使い方:
#   RunTool_DotnetTest.sh <csproj> [--filter <expression>] [--settings <runsettings>] [--digest]
#       [--level diff|wide|full] [--run-id <id>] [--no-record]
#
# dotnet test の全文は tmp/test_timing/full/ へ保存する。--digest では成否・件数・時間と
# 予算超過だけを表示する。exit code は dotnet test の値を返す
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

if [ $# -lt 1 ]; then
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 4
fi

TARGET="$1"
shift
FILTER=""
SETTINGS=""
DIGEST=0
LEVEL=""
RUN_ID_OVERRIDE=""
NO_RECORD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --filter)
      if [ "$#" -lt 2 ]; then echo "--filter には式が必要" >&2; exit 4; fi
      FILTER="$2"; shift 2 ;;
    --settings)
      if [ "$#" -lt 2 ]; then echo "--settings には runsettings のパスが必要" >&2; exit 4; fi
      SETTINGS="$2"; shift 2 ;;
    --digest) DIGEST=1; shift ;;
    --level)
      if [ "$#" -lt 2 ]; then echo "--level には diff / wide / full (旧称 Lv1 / Lv2 / Lv3) を指定すること" >&2; exit 4; fi
      LEVEL="$2"
      case "$LEVEL" in diff) LEVEL=Lv1 ;; wide) LEVEL=Lv2 ;; full) LEVEL=Lv3 ;; Lv1|Lv2|Lv3) ;; *) echo "--level は diff / wide / full (旧称 Lv1 / Lv2 / Lv3) を指定すること" >&2; exit 4 ;; esac
      shift 2 ;;
    --run-id)
      if [ "$#" -lt 2 ]; then echo "--run-id には値が必要" >&2; exit 4; fi
      if [[ ! "$2" =~ ^[A-Za-z0-9_.-]+$ ]]; then echo "--run-id に使用できない文字がある" >&2; exit 4; fi
      RUN_ID_OVERRIDE="$2"; shift 2 ;;
    --no-record) NO_RECORD=1; shift ;;
    *) echo "不明な引数: $1" >&2; exit 4 ;;
  esac
done

cd "$PROJECT_ROOT" || exit 4

TEST_DLL=""
if [ "$(basename "$TARGET")" = "ChocoEngine.Celib-Core.Dotnet.Tests.csproj" ]; then
  FRESHNESS_OUTPUT=$(PYTHONIOENCODING=UTF-8 "$PY" -c '
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from ce_test_level import dotnet_stale_assemblies
issues = dotnet_stale_assemblies(sys.argv[3], Path(sys.argv[2]))
print("\n".join(issues))
sys.exit(1 if issues else 0)
' "$PROJECT_ROOT/tools/python" "$PROJECT_ROOT" "$TARGET" 2>&1)
  FRESHNESS_RC=$?
  if [ "$FRESHNESS_RC" -ne 0 ]; then
    echo "CoreCLR テストを開始しない。DLL が古いか見つからないため、ビルドが必要: $TARGET" >&2
    echo "$FRESHNESS_OUTPUT" >&2
    exit 5
  fi
  TEST_DLL="bin/dotnet/ChocoEngine.Celib-Core.Dotnet.Tests/Debug/net8.0/ChocoEngine.Celib-Core.Tests.dll"
fi

TIMING_DIR="$PROJECT_ROOT/tmp/test_timing"
TRX_DIR="$TIMING_DIR/trx"
FULL_DIR="$TIMING_DIR/full"
mkdir -p "$TRX_DIR" "$FULL_DIR"
if [ -n "$RUN_ID_OVERRIDE" ]; then
  RUN_ID="$RUN_ID_OVERRIDE"
else
  RUN_ID=$("$PY" -c "import datetime; print('coreclr_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')[:-3])")
fi
STARTED_AT=$("$PY" -c "import datetime; print(datetime.datetime.now().astimezone().isoformat())")
START_SEC=$("$PY" -c "import time; print(time.time())")
TRX_PATH="$TRX_DIR/$RUN_ID.trx"
FULL_PATH="$FULL_DIR/$RUN_ID.txt"

if [ -n "$TEST_DLL" ]; then
  DOTNET_ARGS=(test "$TEST_DLL" --logger "trx;LogFileName=$RUN_ID.trx" --results-directory "$TRX_DIR")
else
  DOTNET_ARGS=(test "$TARGET" --no-build --logger "trx;LogFileName=$RUN_ID.trx" --results-directory "$TRX_DIR")
fi
HISTORY_TARGET="$TARGET"
if [ -n "$FILTER" ]; then
  DOTNET_ARGS+=(--filter "$FILTER")
  HISTORY_TARGET="$TARGET;filter=$FILTER"
fi
# 長いフィクスチャの一覧は runsettings の NUnit Where で渡す。VSTest の --filter は項の数に比例して
# 選ぶのが遅く (150 項で 1 本 19 秒)、10 KB を超えると解析に失敗する
if [ -n "$SETTINGS" ]; then
  DOTNET_ARGS+=(--settings "$SETTINGS")
  HISTORY_TARGET="$HISTORY_TARGET;settings=$(basename "$SETTINGS")"
fi
dotnet "${DOTNET_ARGS[@]}" > "$FULL_PATH" 2>&1
DOTNET_RC=$?
FINISH_SEC=$("$PY" -c "import time; print(time.time())")
WALL_SEC=$("$PY" -c "import sys; print(max(0.0, float(sys.argv[1]) - float(sys.argv[2])))" \
  "$FINISH_SEC" "$START_SEC")

TIMING_ARGS=(
  --input "$TRX_PATH" --root "$TIMING_DIR" --run-id "$RUN_ID"
  --kind coreclr --runner dotnet --target "$HISTORY_TARGET"
  --started-at "$STARTED_AT" --wall-sec "$WALL_SEC" --exit-code "$DOTNET_RC"
)
if [ -n "$LEVEL" ]; then TIMING_ARGS+=(--level "$LEVEL"); fi

TIMING_RC=1
if [ "$NO_RECORD" = "1" ]; then
  TIMING_RC=0
elif [ -f "$TRX_PATH" ]; then
  "$PY" "$SCRIPT_DIR/../python/ce_test_timing.py" record-trx \
    "${TIMING_ARGS[@]}" --quiet
  TIMING_RC=$?
  if [ "$TIMING_RC" -ne 0 ]; then
    echo "CoreCLR TRX を時間履歴へ記録できなかった: $TRX_PATH" >&2
  fi
else
  echo "CoreCLR TRX が生成されなかった: $TRX_PATH" >&2
fi

if [ "$DIGEST" = "1" ]; then
  if [ "$NO_RECORD" = "1" ]; then
    echo "CoreCLR shard exit: $DOTNET_RC"
    if [ -f "$TRX_PATH" ]; then echo "trx: ${TRX_PATH#"$PROJECT_ROOT"/}"; fi
    echo "full: ${FULL_PATH#"$PROJECT_ROOT"/}"
    if [ "$DOTNET_RC" -ne 0 ]; then cat "$FULL_PATH"; fi
  elif [ -f "$TRX_PATH" ] && [ "$TIMING_RC" -eq 0 ]; then
    "$PY" "$SCRIPT_DIR/../python/ce_test_timing.py" summary \
      --root "$TIMING_DIR" --run-id "$RUN_ID"
  else
    cat "$FULL_PATH"
    echo "full: ${FULL_PATH#"$PROJECT_ROOT"/}"
  fi
else
  cat "$FULL_PATH"
fi

exit "$DOTNET_RC"
