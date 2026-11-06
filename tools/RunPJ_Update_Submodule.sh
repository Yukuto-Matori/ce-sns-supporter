#!/bin/bash
# =======================================================================
# This script is used to update the Unity packages for the Choco Engine.
# Git の管理外とするため、pull 以外では「.git」フォルダをリネームしておく
# =======================================================================

# ce-shared-tools リポジトリ（共通ツール）を最新化する
echo "* ===== Update ce-shared-tools... ===== "
PT_PATH="ce-shared-tools"
mv "$PT_PATH/.git_back" "$PT_PATH/.git"
git -C "$PT_PATH" pull
mv "$PT_PATH/.git" "$PT_PATH/.git_back"

echo "* All Submodules Updated."
