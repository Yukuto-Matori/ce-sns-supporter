#!/bin/bash
# =======================================================================
# This script is used to Initialize the Unity package for the Choco Engine.
# Git の管理外とするため、「.git」フォルダをリネームする
# 一度初期化してから綺麗に入れなおすため、若干時間が必要(何度実行しても良い)
# =======================================================================

# ce-shared-tools リポジトリ（共通ツール）を導入する
echo "* ===== Initialize ce-shared-tools... ===== "
PT_PATH="ce-shared-tools"
rm -rf "$PT_PATH"
git clone https://github.com/Yukuto-Matori/ce-shared-tools.git "$PT_PATH"
mv "$PT_PATH/.git" "$PT_PATH/.git_back"

echo "* All Submodules Initialized."

