#!/usr/bin/env bash
# CeUnityEditorOperator Phase3: 別プロセスでのクラッシュ耐性テスト実行
#
# Unity 標準の `-batchmode -runTests` を排他制御付きでラップし、
# 結果を RunTool_CeUnityOperator.sh の run-tests と同じ JSON スキーマへ変換する。
# メイン Editor プロセスとは無関係の別プロセスで動くため、
# メイン Editor がクラッシュ・フリーズしていても独立して実行できる。
#
# 設計は docs/Celib-Unity/modules/spec_celib-unity_Editor_CeUnityEditorOperator.md 6.6 を参照。
#
# 使い方:
#   RunTool_CeUnityBatchTest.sh --target "Test.Celib.Util.ArrayUtilTest" [--mode editmode] [--timeout 600]
#   RunTool_CeUnityBatchTest.sh start [--timeout 600]                       # warm server
#     ※ idle timeout は既定10分。--idle-timeout-sec 120 のように start 時だけ変更できる
#   RunTool_CeUnityBatchTest.sh stop                                        # stop warm server
#   RunTool_CeUnityBatchTest.sh stop --all                                  # stop registered warm servers
#   RunTool_CeUnityBatchTest.sh status                                      # report execution route
#   RunTool_CeUnityBatchTest.sh status --all                                # main + clones + 実行ロックの一覧
#     ※ test / stop / clone-setup は他のセッションのテストと重ならないよう実行ロックを取る。
#        使用中なら待ち (既定 3600 秒。CE_TEST_RUN_LOCK_WAIT_SEC で変更)、超えたら exit 3
#   RunTool_CeUnityBatchTest.sh clone-setup --count 3                       # prepare two clones + main
#   RunTool_CeUnityBatchTest.sh --target "Test.A;Test.B"                 # 複数対象はセミコロン区切り
#   RunTool_CeUnityBatchTest.sh --target all                             # 全件 (時間がかかるので --timeout を伸ばす)
#   RunTool_CeUnityBatchTest.sh --target Test.A --wait-batchmode 120     # 既存 batchmode の終了を待つ
#     ※ target=all は既定で自前テスト (Assets/Tests/ 配下) のみ。--include-packages で外部同梱も含める
#   RunTool_CeUnityBatchTest.sh --target ... --unity-exe "C:/path/to/Unity.exe"
#   RunTool_CeUnityBatchTest.sh --target all --baseline tools/ce_test_baseline.json
#     ※ --baseline を付けると、既知の恒常的失敗一覧と突き合わせて新規回帰のみを反映する
#   RunTool_CeUnityBatchTest.sh --target all --exclude-categories Diagnose,Manual
#     ※ 指定したカテゴリを除外する (operator の run-tests と同じ用途)。
#        診断・目視用のテストはここで外す。[Explicit] の診断を回すときは --exclude-categories を
#        付けずにフルネームだけで指定する (付けるとスキップになる。2026-10-09 実測)
#   RunTool_CeUnityBatchTest.sh --target Test.A --level diff
#     ※ 回帰レベルを実行時間履歴へ記録する
#   RunTool_CeUnityBatchTest.sh --target all --exclude-coreclr-assemblies "AssemblyA,AssemblyB"
#     ※ CoreCLR と重なる EditMode assembly を除外し、同じ operator 経路で cold 起動する
#   RunTool_CeUnityBatchTest.sh --target all --digest
#     ※ --digest は結果 JSON をそのまま出さず、判断に必要な情報だけへ要約する
#        (operator の --digest と同じ。AI から呼ぶときは常に付けてよい)。
#        完全な JSON はファイルに残り、要約の最終行 full: がその場所を示す
#   RunTool_CeUnityBatchTest.sh --mode playmode --target "Test.A" --timeout 300
#     ※ playmode は既定で GPU を使う (-nographics を付けない)。URP/VFX 依存の PlayMode テストは
#        -nographics だと RenderTexture.Create failed 等で失敗するため。GPU の無い環境で
#        editmode 相当に倒したいときは --nographics を明示する
#
# 排他制御:
#   status/heartbeat.json と Unity インスタンス状態を確認し、同じプロジェクトの Editor / batchmode
#   が起動中なら Library ロック競合を避けるため実行を拒否する (exit 3)
#
# Unity 実行ファイルの解決順:
#   1. --unity-exe <path>
#   2. 環境変数 CE_UNITY_EDITOR_EXE
#   3. Unity Hub の secondaryInstallPath.json + ProjectSettings/ProjectVersion.txt から自動解決
#   4. 既定の Hub インストール先 (C:/Program Files/Unity/Hub/Editor/<version>/Editor/Unity.exe)
#
# exit code:
#   0 = 成功 (全テスト成功) / 1 = 一部失敗、または結果 XML が得られなかった
#   2 = クライアント側 timeout / 3 = 同じプロジェクトの Unity 起動中・状態判定失敗で拒否
#   4 = 引数不正・Unity 実行ファイルが見つからない
#
# 起動オーバーヘッド (ライセンス認証+プロジェクトロード) が実測で約 35 秒あるため、
# 複数対象をまとめて 1 回で実行すること (--target をセミコロン区切りにする)

set -u

PY=""
for candidate in python python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "Python 3 が見つからない" >&2
  exit 4
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "git リポジトリの中で実行する" >&2
  exit 4
fi
cd "$REPO_ROOT" || exit 4

MODE="editmode"
ACTION="test"
TARGET=""
TIMEOUT_SEC=600
UNITY_EXE="${CE_UNITY_EDITOR_EXE:-}"
BASELINE_PATH=""
NOGRAPHICS=""   # 空 = 未指定 (mode に応じた既定値を使う)
INCLUDE_PACKAGES=0
DIGEST=0
EXCLUDE_CATEGORIES=""
EXCLUDE_CORECLR_ASSEMBLIES=""
UNITY_PARITY_TARGETS=""
WAIT_BATCHMODE_SEC=""
LEVEL=""
COMPILE_BEFORE_TEST=0
IDLE_SHUTDOWN_SEC="${CE_UNITY_OPERATOR_IDLE_TIMEOUT_SEC:-600}"
COLD=0
PROJECT_PATH_ARG=""
CLONE_COUNT=""
STOP_ALL=0
ORIGINAL_ARGS=("$@")

case "${1:-}" in
  start|stop|status|clone-setup) ACTION="$1"; shift ;;
esac

usage() {
  sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --mode) MODE="$2"; shift 2 ;;
    --project-path) PROJECT_PATH_ARG="$2"; shift 2 ;;
    --count) CLONE_COUNT="$2"; shift 2 ;;
    --all) STOP_ALL=1; shift ;;
    --target) TARGET="$2"; shift 2 ;;
    --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
    --unity-exe) UNITY_EXE="$2"; shift 2 ;;
    --baseline) BASELINE_PATH="$2"; shift 2 ;;
    --nographics) NOGRAPHICS=1; shift ;;
    --no-nographics) NOGRAPHICS=0; shift ;;
    --include-packages) INCLUDE_PACKAGES=1; shift ;;
    --digest) DIGEST=1; shift ;;
    --compile-before-test) COMPILE_BEFORE_TEST=1; shift ;;
    --cold) COLD=1; shift ;;
    --idle-timeout-sec) IDLE_SHUTDOWN_SEC="$2"; shift 2 ;;
    --exclude-categories) EXCLUDE_CATEGORIES="$2"; shift 2 ;;
    --exclude-coreclr-assemblies) EXCLUDE_CORECLR_ASSEMBLIES="$2"; shift 2 ;;
    --unity-parity-targets) UNITY_PARITY_TARGETS="$2"; shift 2 ;;
    --capture-test-names) CAPTURE_TEST_NAMES=1; shift ;;
    --level)
      if [ "$#" -lt 2 ]; then
        echo "--level には diff / wide / full (旧称 Lv1 / Lv2 / Lv3) を指定すること" >&2
        exit 4
      fi
      LEVEL="$2"
      case "$LEVEL" in diff) LEVEL=Lv1 ;; wide) LEVEL=Lv2 ;; full) LEVEL=Lv3 ;; Lv1|Lv2|Lv3) ;; *) echo "--level は diff / wide / full (旧称 Lv1 / Lv2 / Lv3) を指定すること" >&2; exit 4 ;; esac
      shift 2 ;;
    --wait-batchmode)
      if [ "$#" -lt 2 ]; then
        echo "--wait-batchmode は秒数を指定すること" >&2
        exit 4
      fi
      WAIT_BATCHMODE_SEC="$2"
      shift 2
      ;;
    *) echo "不明な引数: $1" >&2; usage; exit 4 ;;
  esac
done

# テストの実行・停止・clone 準備は、他のセッションの TestLevel と重ならないよう実行ロックを取る。
# TestLevel の中から呼ばれたとき (CE_TEST_RUN_LOCK_HELD) は取り直さない
case "$ACTION" in
  test|stop|clone-setup)
    if [ -z "${CE_TEST_RUN_LOCK_HELD:-}" ]; then
      LOCK_BASH="$(command -v bash)"
      command -v cygpath >/dev/null 2>&1 && LOCK_BASH="$(cygpath -w "$LOCK_BASH")"
      exec "$PY" tools/python/ce_test_run_lock.py run -- \
        "$LOCK_BASH" tools/bash/RunTool_CeUnityBatchTest.sh "${ORIGINAL_ARGS[@]}"
    fi
    ;;
esac

if [ "$ACTION" = "status" ] && [ "$STOP_ALL" -eq 1 ]; then
  exec "$PY" tools/python/ce_unity_parallel_status.py
fi

PROJECT_PATH="${PROJECT_PATH_ARG:-$REPO_ROOT}"
PROJECT_PATH="$($PY -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PROJECT_PATH")"
CLONE_ROOT="$($PY tools/python/ce_test_clone.py root --project-root "$REPO_ROOT")"
if ! "$PY" - "$PROJECT_PATH" "$REPO_ROOT" "$CLONE_ROOT" <<'PYEOF'
import os, sys
project, source, clone_root = (os.path.normcase(os.path.realpath(value)) for value in sys.argv[1:])
if project != source and os.path.commonpath((project, clone_root)) != clone_root:
    raise SystemExit(1)
PYEOF
then
  echo "--project-path は source project または登録 clone 内を指定する" >&2
  exit 4
fi
OPERATOR_ROOT="$PROJECT_PATH/tmp/ce_unity_editor_operator"
WORK_DIR="$PROJECT_PATH/tmp/ce_unity_batch_test"
HEARTBEAT_FILE="$OPERATOR_ROOT/status/heartbeat.json"
WARM_SERVER_FILE="$WORK_DIR/warm_server.json"
operator_command() {
  CE_OPERATOR_ROOT="$OPERATOR_ROOT" CE_TEST_TIMING_RUNNER="${CE_TEST_TIMING_RUNNER:-operator}" \
    bash "$REPO_ROOT/tools/bash/RunTool_CeUnityOperator.sh" "$@"
}

if [ "$ACTION" = "clone-setup" ]; then
  SETUP_ARGS=(clone-setup --project-root "$REPO_ROOT")
  [ -n "$CLONE_COUNT" ] && SETUP_ARGS+=(--count "$CLONE_COUNT")
  exec "$PY" tools/python/ce_test_clone.py "${SETUP_ARGS[@]}"
fi

if [ -n "${CE_UNITY_BATCHTEST_COLD:-}" ]; then COLD=1; fi
if ! [[ "$IDLE_SHUTDOWN_SEC" =~ ^[0-9]+$ ]]; then
  echo "--idle-timeout-sec は0以上の秒数を指定すること" >&2
  exit 4
fi
if [ "$ACTION" = "start" ]; then
  export CE_UNITY_OPERATOR_IDLE_TIMEOUT_SEC="$IDLE_SHUTDOWN_SEC"
fi

if [ "$ACTION" = "test" ] && [ -z "$TARGET" ]; then
  echo "--target を指定すること (全件なら --target all)" >&2
  exit 4
fi

if [ -n "$WAIT_BATCHMODE_SEC" ] && ! [[ "$WAIT_BATCHMODE_SEC" =~ ^[0-9]+$ ]]; then
  echo "--wait-batchmode は秒数を指定すること" >&2
  exit 4
fi

# 既定: editmode は -nographics (描画不要・軽量)。playmode は GPU を使う
# (URP/VFX 依存のテストが -nographics だと RenderTexture.Create failed 等で軒並み失敗するため。
# 2026-08-17 実機 spike で確認済)
if [ -z "$NOGRAPHICS" ]; then
  if [ "$MODE" = "playmode" ]; then
    NOGRAPHICS=0
  else
    NOGRAPHICS=1
  fi
fi
GRAPHICS_ARGS=()
[ "$NOGRAPHICS" = "1" ] && GRAPHICS_ARGS+=(-nographics)

# --- 1. 排他制御: メイン Editor が起動中なら Library ロック競合を避けるため拒否する ---
STATUS_TOOL="$REPO_ROOT/tools/bash/RunTool_UnityInstanceStatus.sh"
refresh_unity_status() {
  UNITY_STATUS_JSON="$(bash "$STATUS_TOOL" --project-path "$PROJECT_PATH" --json 2>&1)"
  UNITY_STATUS_RC=$?
}

status_has_no_instances() {
  printf '%s' "$UNITY_STATUS_JSON" | "$PY" -c '
import json, sys
try:
    print("1" if not json.load(sys.stdin).get("instances") else "0")
except (ValueError, TypeError):
    print("0")
' | grep -qx 1
}

cleanup_stale_project_lockfile() {
  if [ "$UNITY_STATUS_RC" -ne 0 ] && [ "$UNITY_STATUS_RC" -ne 12 ]; then return 0; fi
  [ -f "$PROJECT_PATH/Temp/UnityLockfile" ] || return 0
  HAS_PROJECT_PROCESS=$(printf '%s' "$UNITY_STATUS_JSON" | "$PY" -c '
import json, sys
try:
    data = json.load(sys.stdin)
    active = any(item.get("is_current_project") for item in data.get("instances", []))
    print("1" if active else "0")
except (ValueError, TypeError):
    print("1")
')
  if [ "$HAS_PROJECT_PROCESS" = "0" ]; then
    rm -f "$PROJECT_PATH/Temp/UnityLockfile"
  fi
}

current_project_pid() {
  printf '%s' "$UNITY_STATUS_JSON" | "$PY" -c '
import json, sys
for item in json.load(sys.stdin).get("instances", []):
    if item.get("is_current_project") and item.get("kind") == sys.argv[1]:
        print(item.get("pid", ""))
        break
' "$1"
}

warm_marker_pid() {
  "$PY" - "$WARM_SERVER_FILE" "$PROJECT_PATH" "$UNITY_STATUS_JSON" <<'PYEOF'
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        marker = json.load(stream)
    project_path = os.path.normcase(os.path.realpath(sys.argv[2]))
    marker_path = os.path.normcase(os.path.realpath(marker.get("project_path", "")))
    marker_pid = str(marker.get("pid", ""))
    if not marker_pid or marker_path != project_path:
        raise SystemExit(0)
    status = json.loads(sys.argv[3])
    for item in status.get("instances", []):
        item_path = os.path.normcase(os.path.realpath(item.get("project_path", "")))
        if (
            str(item.get("pid")) == marker_pid
            and item.get("kind") == "batchmode"
            and item.get("is_current_project")
            and item_path == project_path
        ):
            print(marker_pid)
            break
except (OSError, ValueError, TypeError):
    pass
PYEOF
}

warm_server_matches_status() {
  local marker_pid
  [ "$UNITY_STATUS_RC" -eq 11 ] || return 1
  marker_pid="$(warm_marker_pid)"
  [ -n "$marker_pid" ] || return 1
  printf '%s' "$UNITY_STATUS_JSON" | "$PY" -c '
import json, sys
pid = str(sys.argv[1])
print("1" if any(
    item.get("is_current_project")
    and item.get("kind") == "batchmode"
    and str(item.get("pid")) == pid
    for item in json.load(sys.stdin).get("instances", [])
) else "0")
' "$marker_pid" | grep -qx 1
}

execution_path() {
  case "$UNITY_STATUS_RC" in
    10) printf 'editor-operator' ;;
    11) if warm_server_matches_status; then printf 'warm-batchmode'; else printf 'busy-batchmode'; fi ;;
    0|12) printf 'cold-batchmode' ;;
    *) printf 'unavailable' ;;
  esac
}

format_unity_instances() {
  local kind="$1"
  printf '%s' "$UNITY_STATUS_JSON" | "$PY" -c '
import json, sys
for item in json.load(sys.stdin).get("instances", []):
    if item.get("is_current_project") and item.get("kind") == sys.argv[1]:
        print("pid={}".format(item.get("pid", "?")))
        break
' "$kind"
}

refresh_unity_status

if [ "$ACTION" = "stop" ] && [ "$STOP_ALL" -eq 1 ]; then
  STOP_ALL_RC=0
  for marker in "$REPO_ROOT/tmp/ce_unity_batch_test/warm_server.json" "$CLONE_ROOT"/c*/tmp/ce_unity_batch_test/warm_server.json; do
    [ -f "$marker" ] || continue
    marker_project="$($PY - "$marker" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        print(json.load(stream).get("project_path", ""))
except (OSError, ValueError, TypeError):
    print("")
PYEOF
)"
    if [ -z "$marker_project" ]; then
      echo "warm server marker is unreadable: $marker" >&2
      STOP_ALL_RC=1
      continue
    fi
    bash "$REPO_ROOT/tools/bash/RunTool_CeUnityBatchTest.sh" stop \
      --project-path "$marker_project" --timeout "$TIMEOUT_SEC" --digest || STOP_ALL_RC=$?
  done
  bash "$STATUS_TOOL" --json
  STATUS_ALL_RC=$?
  [ "$STATUS_ALL_RC" -eq 3 ] && exit 3
  exit "$STOP_ALL_RC"
fi

if [ "$ACTION" = "status" ]; then
  PATH_NAME="$(execution_path)"
  printf '%s
' "$PATH_NAME"
  [ "$PATH_NAME" != "unavailable" ] && [ "$PATH_NAME" != "busy-batchmode" ]
  exit $?
fi

if [ "$ACTION" = "stop" ]; then
  if [ "$UNITY_STATUS_RC" -ne 11 ]; then
    if [ "$UNITY_STATUS_RC" -eq 0 ] || [ "$UNITY_STATUS_RC" -eq 12 ]; then
      cleanup_stale_project_lockfile
      rm -f "$WARM_SERVER_FILE"
      echo "warm batchmode server is not running"
      exit 0
    fi
    echo "warm server を安全に停止できない (Unity status=$UNITY_STATUS_RC): $UNITY_STATUS_JSON" >&2
    exit 3
  fi
  if ! warm_server_matches_status; then
    echo "この batchmode は warm server として登録されていないため停止を拒否した" >&2
    exit 3
  fi
  SERVER_PID="$(warm_marker_pid)"
  operator_command stop --timeout 30 --digest
  STOP_RC=$?
  STOP_DEADLINE=$((SECONDS + 30))
  refresh_unity_status
  while [ "$SECONDS" -lt "$STOP_DEADLINE" ]; do
    if [ "$UNITY_STATUS_RC" -eq 11 ] || { [ "$UNITY_STATUS_RC" -eq 3 ] && status_has_no_instances; }; then
      sleep 1
      refresh_unity_status
      continue
    fi
    break
  done
  if [ "$UNITY_STATUS_RC" -eq 11 ] && warm_server_matches_status; then
    echo "Operator stop 後も Unity が残るため、登録 PID $SERVER_PID を終了する" >&2
    if command -v taskkill >/dev/null 2>&1; then
      taskkill /PID "$SERVER_PID" /T /F >/dev/null 2>&1
    else
      kill "$SERVER_PID" >/dev/null 2>&1
    fi
    STOP_DEADLINE=$((SECONDS + 20))
    refresh_unity_status
    while [ "$UNITY_STATUS_RC" -eq 11 ] && [ "$SECONDS" -lt "$STOP_DEADLINE" ]; do
      sleep 1
      refresh_unity_status
    done
  fi
  if [ "$UNITY_STATUS_RC" -eq 0 ] || [ "$UNITY_STATUS_RC" -eq 12 ]; then
    cleanup_stale_project_lockfile
    rm -f "$WARM_SERVER_FILE"
    echo "warm batchmode server stopped (pid=$SERVER_PID, operator exit=$STOP_RC)"
    exit 0
  fi
  echo "warm server が停止しなかった (Unity status=$UNITY_STATUS_RC): $UNITY_STATUS_JSON" >&2
  exit 3
fi

wait_for_operator_idle() {
  local deadline stable_count expected_pid idle_sample idle heartbeat_stamp previous_stamp pinged
  deadline=$((SECONDS + 180))
  stable_count=0
  previous_stamp=""
  pinged=0
  if [ "$EXECUTION_PATH" = "warm-batchmode" ]; then
    expected_pid="$(warm_marker_pid)"
  else
    expected_pid="$(current_project_pid editor)"
  fi
  [ -n "$expected_pid" ] || return 1

  while [ "$SECONDS" -lt "$deadline" ]; do
    idle_sample=$("$PY" - "$HEARTBEAT_FILE" "$expected_pid" <<'PYEOF'
import datetime, json, re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        heartbeat = json.load(stream)
    stamp = re.sub(r"(\.\d{6})\d+", r"\1", heartbeat["updated_at"])
    if stamp.endswith(("Z", "z")):
        stamp = stamp[:-1] + "+00:00"
    updated = datetime.datetime.fromisoformat(stamp)
    age = (datetime.datetime.now(updated.tzinfo) - updated).total_seconds()
    ready = (
        str(heartbeat.get("pid")) == sys.argv[2]
        and heartbeat.get("state") == "idle"
        and heartbeat.get("current_command_id") is None
        and not heartbeat.get("is_compiling")
        and not heartbeat.get("is_updating")
        and age <= 10
    )
    print("1|{}".format(heartbeat.get("updated_at", "")) if ready else "0|")
except (OSError, ValueError, KeyError, TypeError):
    print("0|")
PYEOF
)
    idle="${idle_sample%%|*}"
    heartbeat_stamp="${idle_sample#*|}"
    if [ "$idle" = "1" ] && [ "$heartbeat_stamp" != "$previous_stamp" ]; then
      previous_stamp="$heartbeat_stamp"
      stable_count=$((stable_count + 1))
      if [ "$pinged" -eq 0 ]; then
        if operator_command ping --timeout 10 --digest >/dev/null 2>&1; then
          pinged=1
        else
          stable_count=0
          previous_stamp=""
        fi
      fi
      if [ "$stable_count" -ge 2 ] && [ "$pinged" -eq 1 ]; then return 0; fi
    else
      if [ "$idle" != "1" ]; then
        stable_count=0
        previous_stamp=""
        pinged=0
      fi
    fi
    sleep 0.2
  done
  echo "compile 後に Operator が 5 秒間 idle で安定しなかった" >&2
  return 1
}

if [ "$ACTION" = "start" ]; then
  if [ "$UNITY_STATUS_RC" -ne 0 ] && [ "$UNITY_STATUS_RC" -ne 12 ]; then
    echo "warm server 起動前にこのプロジェクトの Unity を閉じること (status=$UNITY_STATUS_RC)" >&2
    exit 3
  fi
else
  if [ "$UNITY_STATUS_RC" -eq 11 ] && [ -n "$WAIT_BATCHMODE_SEC" ] && ! warm_server_matches_status; then
    echo "このプロジェクトの batchmode 終了を最大 ${WAIT_BATCHMODE_SEC} 秒待つ" >&2
    WAIT_DEADLINE=$((SECONDS + WAIT_BATCHMODE_SEC))
    while [ "$UNITY_STATUS_RC" -eq 11 ] && [ "$SECONDS" -lt "$WAIT_DEADLINE" ]; do
      sleep 1
      refresh_unity_status
    done
  fi

  case "$UNITY_STATUS_RC" in
    0|12)
      EXECUTION_PATH="cold-batchmode"
      ;;
    10)
      EXECUTION_PATH="editor-operator"
      ;;
    11)
      if warm_server_matches_status; then
        EXECUTION_PATH="warm-batchmode"
      else
        BATCHMODE_DETAILS="$(format_unity_instances batchmode)"
        echo "Unity batchmode がこのプロジェクトを実行中のため拒否した: $BATCHMODE_DETAILS。終了を待つには --wait-batchmode <秒> を指定すること" >&2
        exit 3
      fi
      ;;
    *)
      echo "Unity の起動状態を判定できないため実行を拒否した (status=$UNITY_STATUS_RC): $UNITY_STATUS_JSON" >&2
      exit 3
      ;;
  esac
fi

if [ "$COLD" -eq 1 ] && [ "$EXECUTION_PATH" = "warm-batchmode" ]; then
  echo "--cold は既存 warm server と同時に使えない。先に stop を実行すること" >&2
  exit 3
fi

# --- 2. Unity 実行ファイルの解決 ---
if [ -z "$UNITY_EXE" ]; then
  UNITY_VERSION=$(grep -m1 '^m_EditorVersion:' ProjectSettings/ProjectVersion.txt | sed 's/^m_EditorVersion: //' | tr -d '\r')
  CANDIDATES=()
  SECONDARY_JSON="$HOME/AppData/Roaming/UnityHub/secondaryInstallPath.json"
  if [ -f "$SECONDARY_JSON" ]; then
    SECONDARY_PATH=$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8')))" "$SECONDARY_JSON" 2>/dev/null | tr -d '"')
    if [ -n "$SECONDARY_PATH" ]; then
      CANDIDATES+=("$SECONDARY_PATH/$UNITY_VERSION/Editor/Unity.exe")
    fi
  fi
  CANDIDATES+=("/c/Program Files/Unity/Hub/Editor/$UNITY_VERSION/Editor/Unity.exe")

  for c in "${CANDIDATES[@]+"${CANDIDATES[@]}"}"; do
    if [ -f "$c" ]; then
      UNITY_EXE="$c"
      break
    fi
  done
fi

if [ -z "$UNITY_EXE" ] || [ ! -f "$UNITY_EXE" ]; then
  echo "{\"status\":\"unsupported\",\"error\":{\"message\":\"Unity 実行ファイルが見つからない。--unity-exe か環境変数 CE_UNITY_EDITOR_EXE で指定すること\"}}" >&2
  exit 4
fi


if [ "$ACTION" = "start" ]; then
  mkdir -p "$WORK_DIR"
  cleanup_stale_project_lockfile
  rm -f "$WARM_SERVER_FILE"
  SERVER_LOG="$WORK_DIR/warm_server.editor.log"
  UNITY_EXE_NATIVE="$UNITY_EXE"
  if command -v cygpath >/dev/null 2>&1; then
    UNITY_EXE_NATIVE="$(cygpath -w "$UNITY_EXE")"
  fi
  SERVER_PID=$("$PY" - "$UNITY_EXE_NATIVE" "$PROJECT_PATH" "$SERVER_LOG" "$WARM_SERVER_FILE" <<'PYEOF'
import datetime, json, os, subprocess, sys
exe, project, log_path, marker_path = sys.argv[1:]
flags = 0
if os.name == "nt":
    flags = getattr(subprocess, "DETACHED_PROCESS", 0x00000008) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)
with open(log_path, "ab") as log:
    process = subprocess.Popen(
        [exe, "-batchmode", "-projectPath", project, "-logFile", log_path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        creationflags=flags,
        start_new_session=(os.name != "nt"),
    )
marker = {
    "pid": process.pid,
    "project_path": os.path.realpath(project),
    "log_path": os.path.realpath(log_path),
    "started_at": datetime.datetime.now().astimezone().isoformat(),
}
with open(marker_path, "w", encoding="utf-8") as stream:
    json.dump(marker, stream, ensure_ascii=False, indent=2)
print(process.pid)
PYEOF
)
  if [ -z "$SERVER_PID" ]; then
    echo "warm server を起動できなかった" >&2
    exit 1
  fi
  echo "warm server startup requested (pid=$SERVER_PID, log=$SERVER_LOG)"
  START_DEADLINE=$((SECONDS + TIMEOUT_SEC))
  while [ "$SECONDS" -lt "$START_DEADLINE" ]; do
    refresh_unity_status
    ACTIVE_PID="$(current_project_pid batchmode)"
    HEARTBEAT_READY=$("$PY" - "$HEARTBEAT_FILE" "$SERVER_PID" <<'PYEOF'
import datetime, json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        heartbeat = json.load(stream)
    import re
    stamp = re.sub(r"(\.\d{6})\d+", r"\1", heartbeat["updated_at"])
    if stamp.endswith(("Z", "z")):
        stamp = stamp[:-1] + "+00:00"
    updated = datetime.datetime.fromisoformat(stamp)
    age = (datetime.datetime.now(updated.tzinfo) - updated).total_seconds()
    ready = (
        str(heartbeat.get("pid")) == sys.argv[2]
        and heartbeat.get("state") == "idle"
        and age <= 15
        and not heartbeat.get("is_compiling")
        and not heartbeat.get("is_updating")
    )
    print("1" if ready else "0")
except (OSError, ValueError, KeyError, TypeError):
    print("0")
PYEOF
)
    if [ "$UNITY_STATUS_RC" -eq 11 ] && [ "$ACTIVE_PID" = "$SERVER_PID" ] && [ "$HEARTBEAT_READY" = "1" ]; then
      if operator_command ping --timeout 30 --digest; then
        echo "warm server ready (pid=$SERVER_PID)"
        exit 0
      fi
    fi
    if [ "$UNITY_STATUS_RC" -eq 0 ] || [ "$UNITY_STATUS_RC" -eq 12 ]; then
      echo "warm server process exited before becoming ready (pid=$SERVER_PID)" >&2
      rm -f "$WARM_SERVER_FILE"
      exit 1
    fi
    sleep 1
  done
  echo "warm server did not become idle and accept commands within ${TIMEOUT_SEC}s (pid=$SERVER_PID)" >&2
  refresh_unity_status
  if [ "$UNITY_STATUS_RC" -eq 11 ] && warm_server_matches_status; then
    if command -v taskkill >/dev/null 2>&1; then taskkill /PID "$SERVER_PID" /T /F >/dev/null 2>&1; else kill "$SERVER_PID" >/dev/null 2>&1; fi
    STOP_DEADLINE=$((SECONDS + 20))
    refresh_unity_status
    while [ "$UNITY_STATUS_RC" -eq 11 ] && [ "$SECONDS" -lt "$STOP_DEADLINE" ]; do
      sleep 1
      refresh_unity_status
    done
  fi
  if [ "$UNITY_STATUS_RC" -eq 0 ] || [ "$UNITY_STATUS_RC" -eq 12 ]; then
    cleanup_stale_project_lockfile
    rm -f "$WARM_SERVER_FILE"
  else
    echo "停止を確認できないため warm_server.json を保持し、次の stop で登録 PID を確認する" >&2
  fi
  exit 2
fi

if [ "$EXECUTION_PATH" = "cold-batchmode" ] && [ "$COLD" -eq 0 ]; then
  START_OUTPUT=$(CE_UNITY_OPERATOR_IDLE_TIMEOUT_SEC="$IDLE_SHUTDOWN_SEC" CE_OPERATOR_ROOT="$OPERATOR_ROOT" bash "$REPO_ROOT/tools/bash/RunTool_CeUnityBatchTest.sh" start --project-path "$PROJECT_PATH" --timeout "$TIMEOUT_SEC" 2>&1)
  START_RC=$?
  [ -n "$START_OUTPUT" ] && echo "$START_OUTPUT"
  if [ "$START_RC" -ne 0 ]; then exit "$START_RC"; fi
  EXECUTION_PATH="warm-batchmode"
  echo "Unity execution path: warm-batchmode"
elif [ "$EXECUTION_PATH" = "warm-batchmode" ] || [ "$EXECUTION_PATH" = "editor-operator" ]; then
  echo "Unity execution path: $EXECUTION_PATH"
fi

if [ "$EXECUTION_PATH" = "warm-batchmode" ] || [ "$EXECUTION_PATH" = "editor-operator" ]; then
  if [ "$COMPILE_BEFORE_TEST" -eq 1 ]; then
    COMPILE_START=$("$PY" -c "import time; print(time.monotonic())")
    operator_command compile --timeout "$TIMEOUT_SEC" --digest
    COMPILE_RC=$?
    COMPILE_END=$("$PY" -c "import time; print(time.monotonic())")
    COMPILE_WALL=$("$PY" -c "import sys; print(max(0.0, float(sys.argv[1]) - float(sys.argv[2])))" "$COMPILE_END" "$COMPILE_START")
    echo "Unity compile wall: ${COMPILE_WALL}s"
    if [ "$COMPILE_RC" -ne 0 ]; then exit "$COMPILE_RC"; fi
    IDLE_WAIT_START=$("$PY" -c "import time; print(time.monotonic())")
    if ! wait_for_operator_idle; then exit 2; fi
    IDLE_WAIT_END=$("$PY" -c "import time; print(time.monotonic())")
    IDLE_WAIT_WALL=$("$PY" -c "import sys; print(max(0.0, float(sys.argv[1]) - float(sys.argv[2])))" "$IDLE_WAIT_END" "$IDLE_WAIT_START")
    echo "Operator idle wait wall: ${IDLE_WAIT_WALL}s"
  fi
  OPERATOR_ARGS=(run-tests --mode "$MODE" --target "$TARGET" --timeout "$TIMEOUT_SEC" --digest)
  [ "$INCLUDE_PACKAGES" -eq 1 ] && OPERATOR_ARGS+=(--include-packages)
  [ -n "$EXCLUDE_CATEGORIES" ] && OPERATOR_ARGS+=(--exclude-categories "$EXCLUDE_CATEGORIES")
  [ -n "$EXCLUDE_CORECLR_ASSEMBLIES" ] && OPERATOR_ARGS+=(--exclude-coreclr-assemblies "$EXCLUDE_CORECLR_ASSEMBLIES")
  [ -n "$UNITY_PARITY_TARGETS" ] && OPERATOR_ARGS+=(--unity-parity-targets "$UNITY_PARITY_TARGETS")
  [ "${CAPTURE_TEST_NAMES:-0}" -eq 1 ] && OPERATOR_ARGS+=(--capture-test-names)
  [ -n "$BASELINE_PATH" ] && OPERATOR_ARGS+=(--baseline "$BASELINE_PATH")
  [ -n "$LEVEL" ] && OPERATOR_ARGS+=(--level "$LEVEL")
  operator_command "${OPERATOR_ARGS[@]}"
  OPERATOR_RC=$?
  exit "$OPERATOR_RC"
fi

if [ "$COMPILE_BEFORE_TEST" -eq 1 ]; then
  echo "Unity compile wall: included in cold batchmode startup"
fi
echo "Unity execution path: cold-batchmode"

if [ "$EXECUTION_PATH" = "cold-batchmode" ]; then
  mkdir -p "$WORK_DIR"
  COMMAND_DIR="$OPERATOR_ROOT/command"
  PROCESSING_DIR="$OPERATOR_ROOT/processing"
  RESULT_DIR="$OPERATOR_ROOT/result"
  mkdir -p "$COMMAND_DIR" "$PROCESSING_DIR" "$RESULT_DIR"
  COMMAND_ID=$("$PY" -c "import datetime,secrets; print('batchop_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')[:-3] + '_' + secrets.token_hex(2))")
  COMMAND_PATH="$COMMAND_DIR/$COMMAND_ID.command.json"
  RESULT_PATH="$RESULT_DIR/$COMMAND_ID.result.json"
  PROCESSING_PATH="$PROCESSING_DIR/$COMMAND_ID.command.json"
  EDITOR_LOG="$WORK_DIR/$COMMAND_ID.editor.log"
  STARTED_AT=$("$PY" -c "import datetime; print(datetime.datetime.now().astimezone().isoformat())")
  RUNNER_START_SEC=$("$PY" -c "import time; print(time.time())")

  "$PY" - "$COMMAND_PATH.tmp" "$COMMAND_ID" "$MODE" "$TARGET" "$TIMEOUT_SEC" \
    "$INCLUDE_PACKAGES" "$EXCLUDE_CATEGORIES" \
    "$EXCLUDE_CORECLR_ASSEMBLIES" "$UNITY_PARITY_TARGETS" \
    "${CAPTURE_TEST_NAMES:-0}" <<'PYEOF'
import datetime
import json
import sys

(
    output_path,
    command_id,
    mode,
    target,
    timeout_sec,
    include_packages,
    exclude_categories,
    excluded_assemblies,
    parity_targets,
    capture_test_names,
) = sys.argv[1:]

def split_csv(value):
    return [item.strip() for item in value.split(",") if item.strip()]

params = {
    "mode": mode,
    "target": target or "all",
    "include-packages": include_packages == "1",
}
if exclude_categories:
    params["exclude-categories"] = split_csv(exclude_categories)
if excluded_assemblies:
    params["exclude-coreclr-assemblies"] = split_csv(excluded_assemblies)
if parity_targets:
    params["unity-parity-targets"] = split_csv(parity_targets)
if capture_test_names == "1":
    params["capture-test-names"] = True

payload = {
    "id": command_id,
    "command": "run-tests",
    "params": params,
    "timeout_sec": int(timeout_sec),
    "issued_at": datetime.datetime.now().astimezone().isoformat(),
}
with open(output_path, "w", encoding="utf-8", newline="\n") as stream:
    json.dump(payload, stream, ensure_ascii=False, indent=2)
PYEOF
  if [ "$?" -ne 0 ]; then
    echo "cold Operator 命令を生成できなかった" >&2
    exit 4
  fi
  mv "$COMMAND_PATH.tmp" "$COMMAND_PATH"

  UNITY_EXE_NATIVE="$UNITY_EXE"
  if command -v cygpath >/dev/null 2>&1; then
    UNITY_EXE_NATIVE="$(cygpath -w "$UNITY_EXE")"
  fi
  timeout "${TIMEOUT_SEC}s" env CE_UNITY_BATCH_TEST_COMMAND_ID="$COMMAND_ID" \
    "$UNITY_EXE_NATIVE" -batchmode -projectPath "$PROJECT_PATH" \
    -executeMethod Celib.Unity.Editor.CeUnityEditorOperator.RunBatchTestCommand \
    -logFile "$EDITOR_LOG" > "$WORK_DIR/$COMMAND_ID.stdout.log" 2>&1
  UNITY_EXIT=$?
  if [ "$UNITY_EXIT" -eq 124 ]; then
    rm -f "$COMMAND_PATH" "$PROCESSING_PATH"
    echo "{\"status\":\"timeout\",\"error\":{\"message\":\"${TIMEOUT_SEC} 秒で cold Operator run-tests が完了しなかった\"}}" >&2
    exit 2
  fi
  if [ ! -f "$RESULT_PATH" ]; then
    rm -f "$COMMAND_PATH" "$PROCESSING_PATH"
    echo "cold Operator が結果 JSON を出さなかった (Unity exit=$UNITY_EXIT, log=$EDITOR_LOG)" >&2
    exit 1
  fi

  FINISHED_AT=$("$PY" -c "import time; print(time.time())")
  WALL_SEC=$("$PY" -c "import sys; print(max(0.0, float(sys.argv[1]) - float(sys.argv[2])))" "$FINISHED_AT" "$RUNNER_START_SEC")
  TIMING_ARGS=(record-operator --input "$RESULT_PATH" --root "$REPO_ROOT/tmp/test_timing" \
    --run-id "batch_$COMMAND_ID" --kind "$MODE" --runner batch --target "${TARGET:-all}" \
    --exclude-categories "$EXCLUDE_CATEGORIES" --started-at "$STARTED_AT" --wall-sec "$WALL_SEC" --quiet)
  [ -n "$LEVEL" ] && TIMING_ARGS+=(--level "$LEVEL")
  "$PY" tools/python/ce_test_timing.py "${TIMING_ARGS[@]}"
  if [ "$?" -ne 0 ]; then echo "cold Operator run-tests の時間を記録できなかった" >&2; fi

  OUTPUT_RESULT="$RESULT_PATH"
  if [ -n "$BASELINE_PATH" ]; then
    OUTPUT_RESULT="$WORK_DIR/$COMMAND_ID.diff.json"
    "$PY" tools/python/ce_test_baseline_diff.py diff \
      --result "$RESULT_PATH" --baseline "$BASELINE_PATH" > "$OUTPUT_RESULT"
  fi
  if [ "$DIGEST" -eq 1 ]; then
    "$PY" tools/python/ce_output_digest.py operator --result "$OUTPUT_RESULT"
  else
    cat "$OUTPUT_RESULT"
    echo
  fi
  STATUS=$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8')).get('status','error'))" "$OUTPUT_RESULT")
  case "$STATUS" in
    success) exit 0 ;;
    error) exit 1 ;;
    timeout) exit 2 ;;
    *) exit 4 ;;
  esac
fi

# --- 3. batchmode 実行 ---
mkdir -p "$WORK_DIR"
RUN_ID=$("$PY" -c "import datetime; print('batch_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')[:-3])")
RESULT_XML="$WORK_DIR/$RUN_ID.results.xml"
EDITOR_LOG="$WORK_DIR/$RUN_ID.editor.log"

STARTED_AT=$("$PY" -c "import datetime; print(datetime.datetime.now().astimezone().isoformat())")
RUNNER_START_SEC=$("$PY" -c "import time; print(time.time())")

# target=all は「フィルタなし (全件)」を意味する。Unity の -testFilter は文字列一致/正規表現の
# フィルタであり、"all" を渡すと名前に "all" を含むテストだけが対象になってしまう
# (2026-08-17 実機で発覚。例: "Shallowest" や "Callback" が "all" を部分一致で拾った)
FILTER_ARGS=()
if [ "$TARGET" != "all" ]; then
  FILTER_ARGS+=(-testFilter "$TARGET")
elif [ "$INCLUDE_PACKAGES" -eq 0 ]; then
  # target=all は既定で自前テスト (Assets/Tests/ 配下) のみに絞る。
  # 対話 Editor 側の run-tests (13章 CeOperatorTestScope) と同じ絞り込みを別プロセス側でも再現する
  ASSEMBLY_NAMES=$("$PY" tools/python/ce_project_test_assemblies.py --mode "$MODE")
  if [ -n "$ASSEMBLY_NAMES" ]; then
    FILTER_ARGS+=(-assemblyNames "$ASSEMBLY_NAMES")
  fi
fi

# 除外カテゴリは Unity の -testCategory へ "!" 前置で渡す。
# 除外カテゴリを渡すと、名前で指定した [Explicit] もスキップになる (2026-10-09 実測)。
# 診断・目視用の重いテストはカテゴリで外すのが、別プロセス側で使える唯一の手段
if [ -n "$EXCLUDE_CATEGORIES" ]; then
  CATEGORY_FILTER=$(echo "$EXCLUDE_CATEGORIES" | "$PY" -c "
import sys
names = [n.strip() for n in sys.stdin.read().split(',') if n.strip()]
print(';'.join('!' + n for n in names))
")
  if [ -n "$CATEGORY_FILTER" ]; then
    FILTER_ARGS+=(-testCategory "$CATEGORY_FILTER")
  fi
fi

# Unity 本体の stdout/stderr はここで捨てず別ファイルへ逃がす。
# -logFile で editor.log には書かれるが、Windows の Unity batchmode は
# "Aborting batchmode due to failure: ..." のような重要メッセージをコンソールにも出す。
# 呼び出し元へそのまま流すと、末尾の `cat "$ADAPTED_JSON"` の JSON と混ざり、
# クライアント側で「JSON の前に余計な行がある」パースエラーになる (2026-08-17 実機で発覚)。
STDOUT_LOG="$WORK_DIR/$RUN_ID.stdout.log"
timeout "${TIMEOUT_SEC}s" "$UNITY_EXE" -batchmode "${GRAPHICS_ARGS[@]+"${GRAPHICS_ARGS[@]}"}" \
  -projectPath "$PROJECT_PATH" \
  -ceSkipOperator \
  -runTests -testPlatform "$MODE" \
  "${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"}" \
  -testResults "$RESULT_XML" \
  -logFile "$EDITOR_LOG" \
  > "$STDOUT_LOG" 2>&1
UNITY_EXIT=$?

FINISHED_AT=$("$PY" -c "import datetime; print(datetime.datetime.now().astimezone().isoformat())")

if [ "$UNITY_EXIT" -eq 124 ]; then
  echo "{\"status\":\"timeout\",\"error\":{\"message\":\"${TIMEOUT_SEC} 秒でタイムアウトした\"}}" >&2
  exit 2
fi

# --- 4. 結果を既存スキーマへ変換 ---
ADAPTED_JSON="$WORK_DIR/$RUN_ID.adapted.json"
"$PY" tools/python/ce_batch_test_adapter.py \
  --xml "$RESULT_XML" --mode "$MODE" --target "$TARGET" --id "$RUN_ID" \
  --started-at "$STARTED_AT" --finished-at "$FINISHED_AT" --log "$EDITOR_LOG" \
  --stdout-log "$STDOUT_LOG" \
  --exclude-categories "$EXCLUDE_CATEGORIES" \
  > "$ADAPTED_JSON"

if [ ! -f "$RESULT_XML" ]; then
  if [ "$DIGEST" = "1" ]; then
    "$PY" "$REPO_ROOT/tools/python/ce_output_digest.py" operator --result "$ADAPTED_JSON"
  else
    cat "$ADAPTED_JSON"
  fi
  exit 1
fi

# --- 4.1 実行時間を履歴へ記録する ---
RUNNER_FINISH_SEC=$("$PY" -c "import time; print(time.time())")
TIMING_WALL_SEC=$("$PY" -c "import sys; print(max(0.0, float(sys.argv[1]) - float(sys.argv[2])))" \
  "$RUNNER_FINISH_SEC" "$RUNNER_START_SEC")
TIMING_KIND="$MODE"
if [ "$MODE" != "playmode" ]; then TIMING_KIND="editmode"; fi
TIMING_ARGS=(
  --input "$RESULT_XML" --root "$REPO_ROOT/tmp/test_timing" --run-id "$RUN_ID"
  --kind "$TIMING_KIND" --runner batch --target "$TARGET"
  --exclude-categories "$EXCLUDE_CATEGORIES" --started-at "$STARTED_AT"
  --wall-sec "$TIMING_WALL_SEC"
)
if [ -n "$LEVEL" ]; then TIMING_ARGS+=(--level "$LEVEL"); fi
"$PY" tools/python/ce_test_timing.py record-nunit \
  "${TIMING_ARGS[@]}" --quiet
TIMING_RC=$?
if [ "$TIMING_RC" -ne 0 ]; then
  echo "テスト時間を記録できなかった。fixture suite の duration を確認すること" >&2
  exit 1
fi

print_timing_summary() {
  "$PY" tools/python/ce_test_timing.py summary \
    --root "$REPO_ROOT/tmp/test_timing" --run-id "$RUN_ID"
}

# --- 5. --baseline があれば既知の恒常的失敗と突き合わせる ---
DIGEST_PY="$REPO_ROOT/tools/python/ce_output_digest.py"

if [ -n "$BASELINE_PATH" ]; then
  if [ "$DIGEST" = "1" ]; then
    # 突き合わせ後の JSON をファイルへ落としてから要約する。
    # 完全な JSON は残るので、要約で足りないときは full: のパスを読めばよい
    DIFF_JSON="$WORK_DIR/$RUN_ID.diff.json"
    "$PY" tools/python/ce_test_baseline_diff.py diff \
      --result "$ADAPTED_JSON" --baseline "$BASELINE_PATH" > "$DIFF_JSON"
    RC=$?
    "$PY" "$DIGEST_PY" operator --result "$DIFF_JSON"
    if [ "$DIGEST" = "1" ]; then print_timing_summary; fi
    exit $RC
  fi
  "$PY" tools/python/ce_test_baseline_diff.py diff \
    --result "$ADAPTED_JSON" --baseline "$BASELINE_PATH"
  exit $?
fi

if [ "$DIGEST" = "1" ]; then
  "$PY" "$DIGEST_PY" operator --result "$ADAPTED_JSON"
  print_timing_summary
else
  cat "$ADAPTED_JSON"
fi
STATUS=$("$PY" -c "
import json
with open('$ADAPTED_JSON', encoding='utf-8') as f:
    print(json.load(f).get('status', 'error'))
")
[ "$STATUS" = "success" ] && exit 0 || exit 1
