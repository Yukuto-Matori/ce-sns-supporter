#!/usr/bin/env bash
# Addressables のビルド内訳 (buildlayout.json) を要約するラッパ
#
# 使い方:
#   RunTool_SummarizeBuildLayout.sh                 # 直近のビルドの内訳を要約
#   RunTool_SummarizeBuildLayout.sh --top 20        # バンドルごとに 20 件出す
#   RunTool_SummarizeBuildLayout.sh --json          # 機械処理向けに JSON で出す
#   RunTool_SummarizeBuildLayout.sh --path <file>   # 別の buildlayout.json を読む
#
# exit code:
#   0 = 成功 / 1 = レポートが無い / 2 = 実行エラー
#
# 何が分かるか:
#   - どのバンドルに何が入っているか。**明示の登録 (E) と依存で引き込まれた暗黙 (I) を区別できる**
#   - Addressable-List.csv の登録量とビルドの実サイズが食い違うときの原因
#
# 前提:
#   Addressables はコンテンツをビルドするたびにレポートを書き出す。設定変更は要らない。
#   まだ 1 度もビルドしていないときだけ RunTool_CeUnityOperator.sh build-app を先に行う
#
# 背景は docs/03_ai_command_notes.md を参照

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

cd "$REPO_ROOT" || exit 2
exec "$PY" tools/python/summarize_buildlayout.py "$@"
