#!/usr/bin/env bash
# Unity Editor の「フリーズ」と「クラッシュ」を区別する健全性チェック
#
# CeUnityEditorOperator の heartbeat 停滞だけでは、メインスレッドが詰まっている
# だけなのか、プロセスごと落ちたのかを区別できない。本ツールは heartbeat.json の
# pid を OS レベルで生存確認し、死んでいればクラッシュレポートと Editor.log の
# 末尾を添えて報告する。frozen のときは対象 pid のモーダルダイアログも調べる。
#
# 使い方:
#   RunTool_CeUnityHealthCheck.sh [--root <path>] [--stale-sec 10]
#
# exit code:
#   0 = running (正常稼働) / 1 = frozen (フリーズ。modal の title/buttons を添えて報告)
#   2 = crashed (プロセス消滅) / 3 = not_started (heartbeat.json が無い)
#
# 詳細は ai_docs/3_references/Guideline_CeUnityEditorOperator.md を参照

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
  exit 3
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "git リポジトリの中で実行する" >&2
  exit 3
fi
cd "$REPO_ROOT" || exit 3

ROOT_DIR="${CE_OPERATOR_ROOT:-$REPO_ROOT/tmp/ce_unity_editor_operator}"

exec "$PY" tools/python/ce_health_check.py --root "$ROOT_DIR" "$@"
