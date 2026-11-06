#!/usr/bin/env bash
# テキストファイルの文字化け検出ラッパ
#
# 使い方:
#   RunTool_CheckTextEncoding.sh            # 追跡中の全テキストファイルを検査
#   RunTool_CheckTextEncoding.sh --staged   # ステージ済みファイルのみ検査 (pre-commit 用)
#
# exit code:
#   0 = 違反なし / 1 = 違反あり / 2 = 実行エラー
#
# 検出内容と背景は docs/03_ai_command_notes.md を参照

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
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "git リポジトリの中で実行する" >&2
  exit 2
fi

# 検査結果に日本語を含むため出力エンコーディングを固定する。
# Windows の既定は cp932 で、メッセージ出力時に例外になる
PYTHONIOENCODING=utf-8 "$PY" "$REPO_ROOT/tools/python/check_text_encoding.py" "$@"
