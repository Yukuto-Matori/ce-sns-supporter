#!/usr/bin/env bash
# git hooks をインストールする
#
# 使い方:
#   RunTool_InstallGitHooks.sh          # インストール
#   RunTool_InstallGitHooks.sh --check  # インストール済みかを確認するだけ
#
# インストールされる hook:
#   pre-commit ... ステージ済みファイルの文字化けを検出する
#   commit-msg ... PowerShell here-string 混入を検出する
#
# core.hooksPath は変更しない。本リポジトリは Git LFS が
# post-checkout / post-commit / post-merge / pre-push を .git/hooks へ置いており、
# hooksPath を切り替えると LFS 側が無効化されるため

set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "git リポジトリの中で実行する" >&2
  exit 2
fi

HOOK_DIR="$(git rev-parse --git-path hooks)"
HOOK_PATH="$HOOK_DIR/pre-commit"
COMMIT_MSG_HOOK_PATH="$HOOK_DIR/commit-msg"
MARKER="# managed-by: RunTool_InstallGitHooks.sh"

if [ "${1:-}" = "--check" ]; then
  missing=0
  if [ -f "$HOOK_PATH" ] && grep -q "$MARKER" "$HOOK_PATH" 2>/dev/null; then
    echo "pre-commit はインストール済み: $HOOK_PATH"
  else
    echo "pre-commit は未インストール: $HOOK_PATH" >&2
    missing=1
  fi
  if [ -f "$COMMIT_MSG_HOOK_PATH" ] && grep -q "$MARKER" "$COMMIT_MSG_HOOK_PATH" 2>/dev/null; then
    echo "commit-msg はインストール済み: $COMMIT_MSG_HOOK_PATH"
  else
    echo "commit-msg は未インストール: $COMMIT_MSG_HOOK_PATH" >&2
    missing=1
  fi
  if [ "$missing" -ne 0 ]; then
    echo "RunTool_InstallGitHooks.sh を実行して Git hook を導入する" >&2
    exit 1
  fi
  exit 0
fi

# 自前管理でない既存 hook は上書きしない。手書きの hook を消すと復旧できないため
if [ -f "$HOOK_PATH" ] && ! grep -q "$MARKER" "$HOOK_PATH" 2>/dev/null; then
  echo "既存の pre-commit がある。内容を確認して手動で統合する: $HOOK_PATH" >&2
  exit 1
fi
if [ -f "$COMMIT_MSG_HOOK_PATH" ] && ! grep -q "$MARKER" "$COMMIT_MSG_HOOK_PATH" 2>/dev/null; then
  echo "既存の commit-msg がある。内容を確認して手動で統合する: $COMMIT_MSG_HOOK_PATH" >&2
  exit 1
fi

mkdir -p "$HOOK_DIR"
cat > "$HOOK_PATH" <<'HOOK'
#!/usr/bin/env bash
# managed-by: RunTool_InstallGitHooks.sh
# ステージ済みファイルの文字化けを検出する。再インストールは RunTool_InstallGitHooks.sh

set -u

REPO_ROOT="$(git rev-parse --show-toplevel)"
bash "$REPO_ROOT/tools/bash/RunTool_CheckTextEncoding.sh" --staged || {
  echo "" >&2
  echo "文字化けを検出したためコミットを中止した。" >&2
  echo "意図的なら --no-verify で回避できるが、まず内容を確認する。" >&2
  exit 1
}
HOOK

chmod +x "$HOOK_PATH"

cat > "$COMMIT_MSG_HOOK_PATH" <<'HOOK'
#!/usr/bin/env bash
# managed-by: RunTool_InstallGitHooks.sh
# コミットメッセージの PowerShell here-string 混入を検出する

set -u

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECKER="$REPO_ROOT/ce-shared-tools/tools/bash/RunTool_CheckCommitMessage.sh"
if [ ! -f "$CHECKER" ]; then
  echo "コミットメッセージ検査ツールが見つからない: $CHECKER" >&2
  echo "ce-shared-tools を更新してから hook を再導入する" >&2
  exit 1
fi

bash "$CHECKER" "$1"
HOOK

chmod +x "$COMMIT_MSG_HOOK_PATH"
echo "pre-commit をインストールした: $HOOK_PATH"
echo "commit-msg をインストールした: $COMMIT_MSG_HOOK_PATH"
