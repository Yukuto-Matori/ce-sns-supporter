#!/usr/bin/env bash
# Unity.exe ごとの種類・対象プロジェクト・ウィンドウ状態を表示する

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

exec "$PY" tools/python/ce_unity_instance_status.py "$@"
