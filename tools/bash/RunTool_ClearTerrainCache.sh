#!/usr/bin/env bash
# FromU の地形キャッシュを Unity を起動せずに削除するラッパ
#
# 使い方:
#   RunTool_ClearTerrainCache.sh                    # 消さずに一覧する (現在のアプリ設定のみ)
#   RunTool_ClearTerrainCache.sh --yes              # 実際に削除する
#   RunTool_ClearTerrainCache.sh --all-apps         # apps.jsonc の全アプリを対象に一覧
#   RunTool_ClearTerrainCache.sh --all-apps --yes   # 全アプリぶん削除する
#
# exit code:
#   0 = 成功 / 1 = 削除に失敗したファイルがある / 2 = 実行エラー
#
# どちらを使うか:
#   - **Unity Editor が生きているならテストを名指しするほうが素直**。
#     削除の実装 (TerrainGenerator) をそのまま通るため、置き場の知識が二重にならない
#       RunTool_CeUnityOperator.sh run-tests --timeout 300 \
#         --target Test.TestTool.FromU_TestTool.RemoveWholeStaticWorldData_Succ_1
#   - **本ツールは Editor が落ちている・応答しないとき用**。Unity を起動せずに消せる
#
# 注意:
#   キャッシュの置き場は persistentDataPath であり productName ごとに分かれる。
#   **switch-app で対象アプリを切り替えると置き場も変わる**ため、
#   古いアプリ名のキャッシュが残っていることがある (--all-apps で確認できる)
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
exec "$PY" tools/python/ce_clear_terrain_cache.py --project-root "$REPO_ROOT" "$@"
