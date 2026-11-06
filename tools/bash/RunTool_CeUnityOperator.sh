#!/usr/bin/env bash
# CeUnityEditorOperator クライアントラッパ
# 命令投函 -> 結果ポーリング -> stdout 出力 -> exit code を 1 コマンドに畳む
#
# 使い方:
#   RunTool_CeUnityOperator.sh ping
#   RunTool_CeUnityOperator.sh compile [--force] [--timeout 120]
#   RunTool_CeUnityOperator.sh list-tests [--mode editmode] [--prefix Test.Celib.Util] [--include-packages]
#   RunTool_CeUnityOperator.sh run-tests [--mode editmode] [--target all] [--timeout 900] [--include-packages]
#   RunTool_CeUnityOperator.sh run-tests --target-file tmp/test-targets.txt
#     ※ --target は "Test.A;Test.B" のセミコロン区切りで複数を指定できる
#     [--capture-output]          テストが書き出した文字列を結果へ載せる (診断テスト用)。
#                                 既定では集めない。Unity の Output は Debug.Log も取り込むため
#     [--categories A,B]          指定したカテゴリだけを実行する
#     [--exclude-categories A,B]  指定したカテゴリを除外する (例: WorldGen で重い世界生成を外す)
#                                        [--baseline tools/ce_test_baseline.json]
#     ※ target=all は既定で自前テスト (Assets/Tests/ 配下) のみ。
#        --include-packages で外部同梱 (UniVRM 一式) のテストも含める
#     ※ --baseline を付けると、既知の恒常的失敗一覧と突き合わせて新規回帰のみを
#        status/exit code に反映する (data.new_failures / data.resolved を追加)。
#        baseline の更新は tools/python/ce_test_baseline_diff.py update を直接使う
#   RunTool_CeUnityOperator.sh console-logs [--level error] [--count 50] [--since ISO8601] [--clear]
#   RunTool_CeUnityOperator.sh scene-status
#   RunTool_CeUnityOperator.sh save-scenes
#   RunTool_CeUnityOperator.sh open-scene --scene Assets/Scenes/FromU/FromULaunchScene.unity \
#                                        [--on-dirty save|discard|refuse] [--confirm]
#   RunTool_CeUnityOperator.sh bake-ui --provider vmusicstage-playrec|fromu-field
#   RunTool_CeUnityOperator.sh save-prefab
#   RunTool_CeUnityOperator.sh save-prefab --scene Assets/Scenes/FromU/Inner_FromUFieldScene.unity \
#                                        --source FieldPlay_WinGrp \
#                                        --prefab Assets/AppAssets/FromU/Prehabs/GUI/FieldPlay_WinGrp.prefab
#   RunTool_CeUnityOperator.sh patch-ui --prefab Assets/AppAssets/FromU/Prehabs/GUI/Menu_WinGrp.prefab \
#                                      --set "Layout/NewGame_Button@RectTransform.sizeDelta=440,64" [--set ...]
#   RunTool_CeUnityOperator.sh execute-method --type FromU.Editor.DebugDataScreenBuilder \
#                                           --method BuildAndPlace [--args '{"key":"value"}']
#   RunTool_CeUnityOperator.sh dump-ui-tree --prefab Assets/AppAssets/FromU/Prehabs/GUI/Menu_WinGrp.prefab \
#                                        [--max-depth N] [--path UI/Child] [--fields name,rect,sprite] [--ascii] \
#                                        [--out tmp/ui_capture/menu-tree.txt]
#   RunTool_CeUnityOperator.sh dump-ui-tree --scene Assets/Scenes/FromU/Inner_FromUFieldScene.unity \
#                                        [--out tmp/ui_capture/field-tree.txt]
#   RunTool_CeUnityOperator.sh capture-ui --prefab Assets/AppAssets/FromU/Prehabs/GUI/Menu_WinGrp.prefab \
#                                        --resolution 1920x1080 --out tmp/ui_capture/menu.png
#   RunTool_CeUnityOperator.sh capture-ui --scene Assets/Scenes/FromU/FromULaunchScene.unity \
#                                        [--ui-group DebugData] [--activate UI/Path] [--deactivate UI/Path] \
#                                        [--resolve-labels ja|en] \
#                                        --resolution 1920x1080 --out tmp/ui_capture/launch.png
#   RunTool_CeUnityOperator.sh refresh-assets
#   RunTool_CeUnityOperator.sh switch-app --app fromu [--open-scene]
#   RunTool_CeUnityOperator.sh build-app --app fromu [--bump none|patch|minor|major]
#                                        [--build-target StandaloneWindows64] [--timeout 3600]
#     ※ build-app は分単位で Editor を占有する。--timeout は 1800 秒以上を推奨
#   RunTool_CeUnityOperator.sh resource-rules-inspect --path Assets/Addressable/ce-res/...
#   RunTool_CeUnityOperator.sh addressable-register --scope project --app fromu --dry-run
#   RunTool_CeUnityOperator.sh addressable-register --scope project --app fromu --confirm
#   RunTool_CeUnityOperator.sh addressable-register --scope all --confirm
#     ※ 設定を書き換える project / all は --confirm が必須。確認だけなら --dry-run を使う
#   RunTool_CeUnityOperator.sh rebake-fromu-field --confirm [--timeout 120]
#     ※ 既存の FromU Field シーンを削除して作り直すため --confirm が必須
#   RunTool_CeUnityOperator.sh <cmd> --answer-modal save
#   RunTool_CeUnityOperator.sh <cmd> --answer-modal discard --confirm
#
# 共通オプション:
#   --digest   結果 JSON をそのまま出さず、判断に必要な情報だけへ要約する。
#              AI から呼ぶときは常に付けてよい (実測で出力量が約 1/6 になる)。
#              完全な JSON はファイルに残り、要約の最終行 full: がその場所を示す
#
# exit code:
#   0 = success / 1 = error / 2 = timeout / 3 = Unity 未起動 / 4 = unsupported, interrupted
#   5 = heartbeat 停滞かつモーダル検出 / 6 = heartbeat 停滞かつモーダル未検出・検出不能
#
# 詳細は ai_docs/3_references/Guideline_CeUnityEditorOperator.md を参照

set -u

# python3 は Windows の Microsoft Store スタブが割り込むことがあるため python を優先する
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ルートディレクトリの解決順は Unity 側と揃える (環境変数 -> 既定値)
ROOT_DIR="${CE_OPERATOR_ROOT:-$PROJECT_ROOT/tmp/ce_unity_editor_operator}"

# heartbeat が古いと判断する秒数
HEARTBEAT_STALE_SEC="${CE_OPERATOR_HEARTBEAT_STALE_SEC:-10}"
# 待機中に heartbeat 停滞を打ち切る秒数
# ドメインリロードと非フォーカス時のスロットリングで 1 分程度の停滞は起こりうるため長めに取る
HEARTBEAT_STALL_SEC="${CE_OPERATOR_HEARTBEAT_STALL_SEC:-120}"
# 投函直後の高頻度ポーリングを続ける秒数
FAST_POLL_WINDOW_SEC="${CE_OPERATOR_FAST_POLL_WINDOW_SEC:-2}"

usage() {
  sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if [ $# -lt 1 ]; then
  usage
  exit 4
fi

COMMAND="$1"
shift

case "$COMMAND" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

# run-tests は他のセッションの TestLevel と重ならないよう実行ロックを取る。
# TestLevel・BatchTest の中から呼ばれたとき (CE_TEST_RUN_LOCK_HELD) は取り直さない
if [ "$COMMAND" = "run-tests" ] && [ -z "${CE_TEST_RUN_LOCK_HELD:-}" ]; then
  LOCK_BASH="$(command -v bash)"
  command -v cygpath >/dev/null 2>&1 && LOCK_BASH="$(cygpath -w "$LOCK_BASH")"
  exec "$PY" "$PROJECT_ROOT/tools/python/ce_test_run_lock.py" run -- \
    "$LOCK_BASH" "$SCRIPT_DIR/RunTool_CeUnityOperator.sh" "$COMMAND" "$@"
fi

TIMEOUT_SEC=0
PARAM_ARGS=()
BASELINE_PATH=""
DIGEST=0
ANSWER_MODAL=""
CONFIRM_REQUESTED=0
MODAL_ANSWERED=0
TIMING_MODE="editmode"
TIMING_TARGET=""
TARGET_FILE=""
TIMING_EXCLUDE_CATEGORIES=""

# 引数をコマンド固有パラメータへ振り分ける
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      TIMEOUT_SEC="$2"; shift 2 ;;
    --root)
      ROOT_DIR="$2"; shift 2 ;;
    --baseline)
      # run-tests 専用。Unity へは送らずクライアント側で結果の突き合わせに使う
      BASELINE_PATH="$2"; shift 2 ;;
    --digest)
      # 結果 JSON をそのまま出さず要約する。完全な JSON はファイルに残り最終行で示される
      DIGEST=1; shift ;;
    --answer-modal)
      if [ "$#" -lt 2 ]; then
        echo '{"status":"error","error":{"message":"--answer-modal には save または discard が必要"}}' >&2
        exit 4
      fi
      ANSWER_MODAL="$2"; shift 2 ;;
    --force|--clear|--include-packages|--open-scene|--confirm|--dry-run|--capture-output|--capture-test-names|--ascii|--reuse-compile-domain-reset)
      if [ "$1" = "--confirm" ]; then CONFIRM_REQUESTED=1; fi
      PARAM_ARGS+=("${1#--}=bool:true"); shift ;;
    --count)
      PARAM_ARGS+=("count=int:$2"); shift 2 ;;
    --exclude-coreclr-assemblies)
      PARAM_ARGS+=("exclude-coreclr-assemblies=strlist:$2"); shift 2 ;;
    --unity-parity-targets)
      PARAM_ARGS+=("unity-parity-targets=strlist:$2"); shift 2 ;;
    --categories)
      # カテゴリはハンドラ側が string[] で受け取るため配列として送る (カンマ区切り)
      PARAM_ARGS+=("categories=strlist:$2"); shift 2 ;;
    --exclude-categories)
      # 指定したカテゴリのテストを除外する。普段の回帰から重いものを外す用途
      TIMING_EXCLUDE_CATEGORIES="$2"
      PARAM_ARGS+=("exclude-categories=strlist:$2"); shift 2 ;;
    --activate|--deactivate|--fields)
      # UI path / field list はカンマ区切り配列として送る
      PARAM_ARGS+=("${1#--}=strlist:$2"); shift 2 ;;
    --max-depth)
      PARAM_ARGS+=("max-depth=int:$2"); shift 2 ;;
    --set)
      # patch-ui の --set は複数指定できるため、同じキーを配列へ積む
      PARAM_ARGS+=("set=str:$2"); shift 2 ;;
    --mode)
      TIMING_MODE="$2"; PARAM_ARGS+=("mode=str:$2"); shift 2 ;;
    --target)
      TIMING_TARGET="$2"; PARAM_ARGS+=("target=str:$2"); shift 2 ;;
    --target-file)
      TARGET_FILE="$2"; shift 2 ;;
    --prefix|--level|--since|--app|--scope|--bump|--build-target|--scene|--source|--provider|--prefab|--resolution|--out|--on-dirty|--type|--method|--ui-group|--under|--path|--resolve-labels)
      PARAM_ARGS+=("${1#--}=str:$2"); shift 2 ;;
    --args)
      # execute-method の引数は JSON のまま渡す
      PARAM_ARGS+=("args=json:$2"); shift 2 ;;
    --param)
      # 汎用指定: --param key=value (文字列として渡す)
      PARAM_ARGS+=("${2%%=*}=str:${2#*=}"); shift 2 ;;
    *)
      echo "不明な引数: $1" >&2
      usage
      exit 4 ;;
  esac
done

if [ -n "$TARGET_FILE" ]; then
  if [ "$COMMAND" != "run-tests" ]; then
    echo "--target-file は run-tests 専用" >&2
    exit 4
  fi
  if [ -n "$TIMING_TARGET" ]; then
    echo "--target と --target-file は同時に指定できない" >&2
    exit 4
  fi
  if [ ! -f "$TARGET_FILE" ]; then
    echo "--target-file が見つからない: $TARGET_FILE" >&2
    exit 4
  fi
  TIMING_TARGET="target-file:$(basename -- "$TARGET_FILE")"
  PARAM_ARGS+=("target=file:$TARGET_FILE")
fi

is_automation_context() {
  case "${CI:-}" in 1|true|yes|on|TRUE|YES|ON) return 0 ;; esac
  case "${GITHUB_ACTIONS:-}" in 1|true|yes|on|TRUE|YES|ON) return 0 ;; esac
  case "${TF_BUILD:-}" in 1|true|yes|on|TRUE|YES|ON) return 0 ;; esac
  case "${CE_OPERATOR_AUTO_LOOP:-}" in 1|true|yes|on|TRUE|YES|ON) return 0 ;; esac
  [ -n "${JENKINS_URL:-}" ] && return 0
  return 1
}

case "$ANSWER_MODAL" in
  ""|save)
    ;;
  discard)
    if [ "$CONFIRM_REQUESTED" -ne 1 ]; then
      echo '{"status":"error","error":{"message":"--answer-modal discard には --confirm が必須"}}' >&2
      exit 4
    fi
    if is_automation_context; then
      echo '{"status":"error","error":{"message":"CI / 自動ループでは --answer-modal discard を禁止している"}}' >&2
      exit 4
    fi
    ;;
  *)
    echo '{"status":"error","error":{"message":"--answer-modal は save または discard を指定する"}}' >&2
    exit 4
    ;;
esac

COMMAND_DIR="$ROOT_DIR/command"
RESULT_DIR="$ROOT_DIR/result"
HEARTBEAT_FILE="$ROOT_DIR/status/heartbeat.json"

# --- 1. heartbeat の鮮度確認。無駄な待機をしない ---
# heartbeat が「これからメインスレッドを塞ぐ」と予告しているかを返す (1 = 予告あり)
hb_blocking() {
  "$PY" - "$HEARTBEAT_FILE" <<'PYEOF2'
import sys, os, json
path = sys.argv[1]
if not os.path.exists(path):
    print("0"); sys.exit(0)
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    print("1" if data.get("is_main_thread_blocking") else "0")
except Exception:
    print("0")
PYEOF2
}

hb_age() {
  "$PY" - "$HEARTBEAT_FILE" <<'PYEOF'
import sys, os, re, json, time
from datetime import datetime
path = sys.argv[1]
if not os.path.exists(path):
    print("-1"); sys.exit(0)
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    # .NET の "o" 書式は小数部が 7 桁。fromisoformat は 6 桁までしか解釈できないため詰める
    text = re.sub(r"(\.\d{6})\d+", r"\1", data["updated_at"])
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    updated = datetime.fromisoformat(text)
    age = (datetime.now(updated.tzinfo) - updated).total_seconds()
    print("%.1f" % age)
except Exception:
    # 書き込み途中を掴んだ場合はファイルの更新時刻で代替する
    print("%.1f" % (time.time() - os.path.getmtime(path)))
PYEOF
}

find_powershell() {
  local candidate
  for candidate in pwsh powershell powershell.exe; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

invoke_answer_modal() {
  local target_pid="$1"
  local powershell_command answer_timeout
  local args=()

  if ! powershell_command=$(find_powershell); then
    echo '{"status":"error","error":{"message":"PowerShell が見つからないためモーダルへ応答できない"}}'
    return 1
  fi

  answer_timeout="${CE_OPERATOR_ANSWER_MODAL_TIMEOUT_SEC:-10}"
  args+=("-NoProfile" "-NonInteractive" "-ExecutionPolicy" "Bypass")
  args+=("-File" "$SCRIPT_DIR/RunTool_CeUnityAnswerDialog.ps1")
  args+=("-TargetPid" "$target_pid" "-Action" "$ANSWER_MODAL" "-TimeoutSec" "$answer_timeout")
  if [ "$ANSWER_MODAL" = "discard" ]; then
    args+=("-ConfirmDiscard")
  fi

  "$powershell_command" "${args[@]}"
}

wait_for_heartbeat_fresh() {
  local recovery_sec="${CE_OPERATOR_ANSWER_MODAL_RECOVERY_SEC:-10}"
  local now_epoch deadline_epoch age
  now_epoch=$(date +%s)
  deadline_epoch=$((now_epoch + recovery_sec))

  while [ "$(date +%s)" -lt "$deadline_epoch" ]; do
    age=$(hb_age)
    if [ "$age" = "-1" ]; then
      return 1
    fi
    if [ "$(awk -v a="$age" -v t="$HEARTBEAT_STALE_SEC" 'BEGIN{print (a>t)?1:0}')" = "0" ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

emit_stall_health_error() {
  local reason="$1"
  local health_path health_rc wrapper_rc
  local health_status health_pid modal_present
  local answer_attempted=0 answer_rc=-1 answer_output=""

  health_path=$(mktemp "$ROOT_DIR/status/.health_check.XXXXXX")
  "$SCRIPT_DIR/RunTool_CeUnityHealthCheck.sh" \
    --root "$ROOT_DIR" \
    --stale-sec "$HEARTBEAT_STALE_SEC" \
    > "$health_path" 2>/dev/null
  health_rc=$?

  health_status=$("$PY" - "$health_path" <<'PYEOF_STATUS'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as stream:
        print(json.load(stream).get("status", "unknown"))
except Exception:
    print("unknown")
PYEOF_STATUS
)
  health_pid=$("$PY" - "$health_path" <<'PYEOF_PID'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as stream:
        value = json.load(stream).get("pid")
    print("" if value is None else value)
except Exception:
    print("")
PYEOF_PID
)
  modal_present=$("$PY" - "$health_path" <<'PYEOF_MODAL'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as stream:
        value = json.load(stream).get("modal")
    print("1" if isinstance(value, dict) else "0")
except Exception:
    print("0")
PYEOF_MODAL
)

  if [ -n "$ANSWER_MODAL" ] && [ "$MODAL_ANSWERED" -eq 0 ] \
      && [ "$health_status" = "frozen" ] && [ "$modal_present" = "1" ] \
      && [ -n "$health_pid" ]; then
    answer_attempted=1
    answer_output=$(invoke_answer_modal "$health_pid" 2>&1)
    answer_rc=$?
    if [ "$answer_rc" -eq 0 ]; then
      MODAL_ANSWERED=1
      rm -f "$health_path"
      return 0
    fi
  fi

  "$PY" - "$health_path" "$reason" "$health_rc" "$ANSWER_MODAL" \
    "$answer_attempted" "$answer_rc" "$answer_output" <<'PYEOF_HEALTH' >&2
import json
import sys

health_path, reason, health_rc, answer_action, answer_attempted, answer_rc, answer_output = sys.argv[1:8]
try:
    with open(health_path, "r", encoding="utf-8") as stream:
        health = json.load(stream)
except Exception as exc:
    health = {
        "status": "health_check_failed",
        "error": {
            "message": str(exc),
        },
    }

payload = {
    "status": "stalled",
    "error": {
        "message": reason,
        "health_check": health,
        "health_check_exit_code": int(health_rc),
    },
}
if answer_attempted == "1":
    try:
        answer_result = json.loads(answer_output)
    except Exception:
        answer_result = {"status": "invalid_output", "raw": answer_output}
    payload["error"]["answer_modal"] = {
        "action": answer_action,
        "exit_code": int(answer_rc),
        "result": answer_result,
    }
print(json.dumps(payload, ensure_ascii=False))

if health.get("status") == "not_started":
    exit_code = 3
elif health.get("status") == "frozen" and isinstance(health.get("modal"), dict):
    exit_code = 5
else:
    exit_code = 6
sys.exit(exit_code)
PYEOF_HEALTH
  wrapper_rc=$?
  rm -f "$health_path"
  return "$wrapper_rc"
}

AGE=$(hb_age)
if [ "$AGE" = "-1" ]; then
  echo '{"status":"unavailable","error":{"message":"Unity Editor が起動していない (heartbeat.json が無い)"}}' >&2
  exit 3
fi
if [ "$(awk -v a="$AGE" -v t="$HEARTBEAT_STALE_SEC" 'BEGIN{print (a>t)?1:0}')" = "1" ]; then
  emit_stall_health_error "heartbeat が ${AGE} 秒前で停滞している。Unity Editor にフォーカスを当てること"
  STALL_RC=$?
  if [ "$STALL_RC" -eq 0 ]; then
    if ! wait_for_heartbeat_fresh; then
      emit_stall_health_error "モーダル応答後も heartbeat が復帰しない"
      exit $?
    fi
  else
    exit "$STALL_RC"
  fi
fi

# --- 2. 命令ファイルを原子的に投函する ---
CMD_ID=$("$PY" -c "
import datetime, random, string
now = datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')[:-3]
suffix = ''.join(random.choices(string.ascii_lowercase + string.digits, k=4))
print(now + '_' + suffix)
")

mkdir -p "$COMMAND_DIR"
TMP_PATH="$COMMAND_DIR/$CMD_ID.command.json.tmp"
CMD_PATH="$COMMAND_DIR/$CMD_ID.command.json"

"$PY" - "$TMP_PATH" "$CMD_ID" "$COMMAND" "$TIMEOUT_SEC" "${PARAM_ARGS[@]+"${PARAM_ARGS[@]}"}" <<'PYEOF'
import sys, json, datetime
out_path, cmd_id, command, timeout_sec = sys.argv[1:5]
params = {}
for raw in sys.argv[5:]:
    key, _, typed = raw.partition("=")
    kind, _, value = typed.partition(":")
    if kind == "int":
        params[key] = int(value)
    elif kind == "bool":
        params[key] = value.lower() == "true"
    elif kind == "strlist":
        values = [v for v in (item.strip() for item in value.split(",")) if v]
        if key in params:
            params[key].extend(values)
        else:
            params[key] = values
    elif kind == "json":
        params[key] = json.loads(value)
    elif kind == "file" and key == "target":
        with open(value, encoding="utf-8") as stream:
            params[key] = stream.read().rstrip("\r\n")
    elif kind == "str" and key == "set":
        params.setdefault(key, []).append(value)
    else:
        params[key] = value

payload = {
    "id": cmd_id,
    "command": command,
    "params": params,
    "timeout_sec": int(timeout_sec),
    "issued_at": datetime.datetime.now().astimezone().isoformat(),
}
with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
PYEOF

if [ $? -ne 0 ]; then
  echo "命令ファイルの生成に失敗した" >&2
  exit 4
fi

mv "$TMP_PATH" "$CMD_PATH"

# --- 3. 結果の出現をポーリングする ---
RESULT_PATH="$RESULT_DIR/$CMD_ID.result.json"
START_EPOCH=$(date +%s)
if [ "$COMMAND" = "run-tests" ]; then
  TIMING_STARTED_AT=$("$PY" -c "import datetime; print(datetime.datetime.now().astimezone().isoformat())")
  TIMING_START_SEC=$("$PY" -c "import time; print(time.time())")
fi

# クライアント側の待機上限。Unity 側の打ち切りより余裕を持たせる
if [ "$TIMEOUT_SEC" -gt 0 ]; then
  CLIENT_LIMIT_SEC=$((TIMEOUT_SEC + 30))
else
  CLIENT_LIMIT_SEC=330
fi

LAST_HB_OK_EPOCH=$START_EPOCH

while true; do
  if [ -f "$RESULT_PATH" ]; then
    break
  fi

  NOW_EPOCH=$(date +%s)
  ELAPSED=$((NOW_EPOCH - START_EPOCH))

  if [ "$ELAPSED" -ge "$CLIENT_LIMIT_SEC" ]; then
    echo "{\"status\":\"timeout\",\"error\":{\"message\":\"クライアント側で ${ELAPSED} 秒待機したが結果が出なかった\"}}" >&2
    exit 2
  fi

  # 4. heartbeat の停滞監視
  AGE=$(hb_age)
  if [ "$AGE" != "-1" ] && [ "$(awk -v a="$AGE" -v t="$HEARTBEAT_STALE_SEC" 'BEGIN{print (a>t)?1:0}')" = "0" ]; then
    LAST_HB_OK_EPOCH=$NOW_EPOCH
  elif [ $((NOW_EPOCH - LAST_HB_OK_EPOCH)) -ge "$HEARTBEAT_STALL_SEC" ]; then
    # ビルドのようにメインスレッドを塞ぐ処理は heartbeat を更新できない。
    # 塞ぐ直前に予告が書かれていれば停滞とみなさず、打ち切りは --timeout に任せる
    if [ "$(hb_blocking)" = "1" ]; then
      LAST_HB_OK_EPOCH=$NOW_EPOCH
    else
      emit_stall_health_error "heartbeat が ${HEARTBEAT_STALL_SEC} 秒停滞した。Unity Editor にフォーカスを当てるか、Preferences > General > Interaction Mode を No Throttling にすること"
      STALL_RC=$?
      if [ "$STALL_RC" -eq 0 ]; then
        if ! wait_for_heartbeat_fresh; then
          emit_stall_health_error "モーダル応答後も heartbeat が復帰しない"
          exit $?
        fi
        LAST_HB_OK_EPOCH=$NOW_EPOCH
        continue
      fi
      exit "$STALL_RC"
    fi
  fi

  if [ "$ELAPSED" -lt "$FAST_POLL_WINDOW_SEC" ]; then
    sleep 0.1
  else
    sleep 0.5
  fi
done

# --- 4.9 run-tests の計測を履歴へ記録する ---
if [ "$COMMAND" = "run-tests" ]; then
  TIMING_RUN_ID="operator_$CMD_ID"
  TIMING_FINISH_SEC=$("$PY" -c "import time; print(time.time())")
  TIMING_WALL_SEC=$("$PY" -c "import sys; print(max(0.0, float(sys.argv[1]) - float(sys.argv[2])))" \
    "$TIMING_FINISH_SEC" "$TIMING_START_SEC")
  "$PY" "$SCRIPT_DIR/../python/ce_test_timing.py" record-operator \
    --input "$RESULT_PATH" --root "$PROJECT_ROOT/tmp/test_timing" --run-id "$TIMING_RUN_ID" \
    --kind "$TIMING_MODE" --runner "${CE_TEST_TIMING_RUNNER:-operator}" --target "${TIMING_TARGET:-all}" \
    --exclude-categories "$TIMING_EXCLUDE_CATEGORIES" --started-at "$TIMING_STARTED_AT" \
    --wall-sec "$TIMING_WALL_SEC" --quiet
  if [ "$?" -ne 0 ]; then
    echo "operator run-tests の時間を記録できなかった" >&2
  fi
  print_timing_summary() {
    "$PY" "$SCRIPT_DIR/../python/ce_test_timing.py" summary \
      --root "$PROJECT_ROOT/tmp/test_timing" --run-id "$TIMING_RUN_ID"
  }
fi

# --- 5. 結果を stdout へ出力し status に応じた exit code で終了する ---

# run-tests に --baseline が指定されていれば、既知の恒常的失敗と突き合わせて
# 新規回帰の有無で status を引き直す (tools/python/ce_test_baseline_diff.py)
DIGEST_PY="$SCRIPT_DIR/../python/ce_output_digest.py"

if [ "$COMMAND" = "run-tests" ] && [ -n "$BASELINE_PATH" ]; then
  if [ "$DIGEST" = "1" ]; then
    # baseline 突き合わせ後の JSON を一旦ファイルへ落とし、それを要約する。
    # 完全な JSON は残るので、要約で足りないときは full: のパスを読めばよい
    DIFF_PATH="$RESULT_DIR/$CMD_ID.diff.json"
    "$PY" "$SCRIPT_DIR/../python/ce_test_baseline_diff.py" diff \
      --result "$RESULT_PATH" --baseline "$BASELINE_PATH" > "$DIFF_PATH"
    RC=$?
    "$PY" "$DIGEST_PY" operator --result "$DIFF_PATH"
    print_timing_summary
    exit $RC
  fi
  "$PY" "$SCRIPT_DIR/../python/ce_test_baseline_diff.py" diff \
    --result "$RESULT_PATH" --baseline "$BASELINE_PATH"
  exit $?
fi

if [ "$DIGEST" = "1" ]; then
  "$PY" "$DIGEST_PY" operator --result "$RESULT_PATH"
  if [ "$COMMAND" = "run-tests" ]; then print_timing_summary; fi
else
  cat "$RESULT_PATH"
  echo
fi

STATUS=$("$PY" -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    print(json.load(f).get('status', 'error'))
" "$RESULT_PATH")

case "$STATUS" in
  success)     exit 0 ;;
  error)       exit 1 ;;
  timeout)     exit 2 ;;
  unsupported) exit 4 ;;
  interrupted) exit 4 ;;
  *)           exit 1 ;;
esac
