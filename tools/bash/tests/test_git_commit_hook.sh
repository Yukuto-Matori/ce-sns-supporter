#!/usr/bin/env bash
# RunTool_InstallGitHooks.sh が導入する commit-msg hook の統合テスト

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INSTALLER="$PROJECT_ROOT/tools/bash/RunTool_InstallGitHooks.sh"
CHECKER="$PROJECT_ROOT/ce-shared-tools/tools/bash/RunTool_CheckCommitMessage.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ce-git-hook-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO="$TEST_ROOT/repo"
mkdir -p "$REPO/ce-shared-tools/tools/bash"
cp "$CHECKER" "$REPO/ce-shared-tools/tools/bash/RunTool_CheckCommitMessage.sh"
git -C "$REPO" init -q
git -C "$REPO" config user.name "Commit Hook Test"
git -C "$REPO" config user.email "commit-hook-test@example.invalid"

(cd "$REPO" && bash "$INSTALLER" >/dev/null)

# pre-commit は利用側プロジェクトの文字化け検査に依存するため、
# この一時リポジトリでは空の成功 hook に置き換え、commit-msg だけを検証する。
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$REPO/.git/hooks/pre-commit"

printf '%s\n' 'initial' > "$REPO/file.txt"
git -C "$REPO" add file.txt
printf '%s\n' 'chore: initial commit' > "$REPO/message.txt"
git -C "$REPO" commit --file="$REPO/message.txt" -q

printf '%s\n' 'changed' >> "$REPO/file.txt"
git -C "$REPO" add file.txt
printf '%s\n' '@' 'feat: contaminated message' '@' > "$REPO/bad-message.txt"
if git -C "$REPO" commit --file="$REPO/bad-message.txt" >"$TEST_ROOT/bad.out" 2>&1; then
  fail "commit-msg hook が汚染メッセージを受け入れた"
fi
grep -F 'PowerShell here-string' "$TEST_ROOT/bad.out" >/dev/null || fail "hook のエラー理由が出ない"
[ "$(git -C "$REPO" log -1 --format=%B)" = "chore: initial commit" ] || fail "拒否後にコミットが進んだ"

echo 'OK: git commit hook'
