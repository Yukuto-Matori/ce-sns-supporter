#!/usr/bin/env bash
# Worker 終了後に残ったテスト実行プロセスを表示・停止する
#
# 使い方:
#   RunTool_KillOrphanTests.sh                       # 一覧だけ (既定 --dry-run)
#   RunTool_KillOrphanTests.sh --kill                # 一覧の PID を木ごと止める
#   RunTool_KillOrphanTests.sh --kill --stop-warm    # 待機中の warm server (本物と clone) も止める
#
# 対象は本物と clone (unity_parallel.clone_root) を開くテスト用の batchmode・testhost・テストのラッパ。
# Editor の AssetImportWorker、登録済みの warm server、実行中の Worker・ラッパの配下は対象外

set -u

PY=""
for candidate in python python3; do
  if command -v "$candidate" >/dev/null 2>&1 && \
    "$candidate" -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >/dev/null 2>&1; then
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

# Git bash (MSYS) は fork と exec で起動するので、Windows の親を辿っても呼び出し元の bash へ届かない。
# MSYS の親を辿って各 Windows PID を渡し、同じコマンド行で先に呼んだテストのラッパの名前があっても
# 呼び出し元の shell を取り残しと判定しないようにする
caller_pids=""
pid=$$
while [ -r "/proc/$pid/winpid" ]; do
  caller_pids="$caller_pids $(cat "/proc/$pid/winpid")"
  parent=$(cat "/proc/$pid/ppid" 2>/dev/null)
  if [ -z "$parent" ] || [ "$parent" -le 1 ] || [ "$parent" = "$pid" ]; then
    break
  fi
  pid=$parent
done
export CE_KILL_ORPHAN_CALLER_PIDS="$caller_pids"

exec "$PY" tools/python/ce_kill_orphan_tests.py "$@"
