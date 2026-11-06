---
title: AI向けのコマンド発行時の注意事項
description: AI Agent が本リポジトリでコマンドを実行するときに踏みやすい罠と回避策
seealso: [docs/00_docs_index.md, docs/02_setup_dev.md]
---

# AI向けのコマンド発行時の注意事項

本リポジトリで AI Agent がシェルコマンドを実行するときの既知の罠と回避策をまとめる。

## Git Bash の `sed -i` は改行コードを破壊する

**最重要。一括置換に `sed -i` を使わない。**

### 症状

MSYS (Git Bash) の sed はファイルをテキストモードで開くため、読み込み時に CR を捨てて LF で書き戻す。
結果として CRLF のファイルが LF に変換され、**1 行しか変えていないのにファイル全体が差分になる**。

```
変更前: 2d2d 2d0d 0a74 6974 6c65   ---\r\ntitle
変更後: 2d2d 2d0a 7469 746c 65     ---\ntitle
```

### 本リポジトリ特有の悪化要因

- `core.autocrlf` は `false`、`.gitattributes` の `text` 属性も未指定
- **1 ファイル内で CRLF と LF が混在しているファイルが存在する** (例: 208 行中 CR が 114 個)
- このため「CRLF に戻す」単純な修復 (`sed 's/$/\r/'`) を当てると、元が混在だったファイルが全行 CRLF になり**二次被害になる**

### 回避策: Python のバイナリモードを使う

読み書きを `rb` / `wb` で行えば改行コードに一切触れない。

```python
with open(path, "rb") as f:
    data = f.read()
data = data.replace(b"old_string", b"new_string")
with open(path, "wb") as f:
    f.write(data)
```

### 修復手順 (壊してしまった場合)

`sed` は内容の置換自体は正しく行っているため、**HEAD のバイト列を復元してから置換をやり直す**のが確実。
行単位で CR を付け直す方法は混在ファイルを壊すため使わない。

```python
# HEAD の生バイトを取得し、置換を当ててから書き戻す
orig = subprocess.run(["git", "show", f"HEAD:{path}"], capture_output=True).stdout
data = orig.replace(b"old", b"new")
open(path, "wb").write(data)
```

### 検証コマンド

作業後に改行コードが HEAD から変わっていないことを必ず確認する。

```bash
git diff --cached --name-status -M | while IFS=$'\t' read -r st a b; do
  case "$st" in R*) h="$a"; w="$b";; M*) h="$a"; w="$a";; *) continue;; esac
  [ -f "$w" ] || continue
  hc=$(git show "HEAD:$h" 2>/dev/null | tr -cd '\r' | wc -c); wr=$(tr -cd '\r' < "$w" | wc -c)
  { [ "$hc" -eq 0 ] && [ "$wr" -gt 0 ]; } && echo "LF->CRLF: $w"
  { [ "$hc" -gt 0 ] && [ "$wr" -eq 0 ]; } && echo "CRLF->LF: $w"
done
```

## PowerShell でファイル出力するときは `-Encoding utf8` を明示する

`Set-Content` / `Add-Content` は既定でシステム ANSI コードページ (日本語環境では CP932) で書き出す。
日本語コメントを含む `.cs` や `.md` を書き換えると文字化けする。

- `Out-File` は UTF-8 (BOM 付き) になることがある。BOM 付きは frontmatter 解析を壊すため避ける
- そもそも**日本語を含むファイルの一括置換は PowerShell ではなく Python のバイナリモードで行う**

- **`errors='replace'` でファイルを読んで書き戻さない**。壊れた文字が U+FFFD として確定し、復元できなくなる。デコードに失敗したら書き込まずに止める
- 破損を見つけたら `git log --follow` で健全な祖先を探す (改名を跨ぐため `--follow` は必須)

## 文字化けは pre-commit で止める

検出は自動化してある。

| コマンド | 用途 |
|---------|------|
| `bash tools/bash/RunTool_CheckTextEncoding.sh` | 追跡中の全テキストファイルを検査 |
| `bash tools/bash/RunTool_CheckTextEncoding.sh --staged` | ステージ済みのみ検査 (pre-commit が呼ぶ) |
| `bash tools/bash/RunTool_InstallGitHooks.sh` | pre-commit フックを導入する |
| `bash tools/bash/RunTool_InstallGitHooks.sh --check` | 導入済みかを確認する |

検出する違反は 3 種類。

1. UTF-8 としてデコードできない (CP932 等で書き戻した疑い)
2. U+FFFD の混入 (`errors='replace'` で再保存した疑い)
3. `.md` の UTF-8 BOM (ドキュメント規約は BOM なし)

**クローン直後は pre-commit が入っていない**。`.git/hooks` は git 管理外のため、各自で
`RunTool_InstallGitHooks.sh` を 1 度実行する必要がある。

- `core.hooksPath` は変更していない。Git LFS が `.git/hooks` に 4 つの hook を置いており、
  hooksPath を切り替えると LFS 側が無効化されるため
- `--staged` はワークツリーではなく**インデックスの内容**を読む。ステージしていない修正が
  検査結果に混ざるのを防ぐため
- 意図的に U+FFFD を含めたい場合は `tools/config/text_encoding_ignore.txt` に glob を追記する
- CRLF は検査しない。生成物 (`AGENTS.md` / `CLAUDE.md` / `README_FOR_OVERVIEW.md`) が CRLF で
  出力されるため、検出しても対処できずノイズになる

## `git ls-files` のパススペックは `/` を跨いで再帰マッチする

`git ls-files 'docs/*.md'` の `*` はシェルグロブと違い **`/` を含めてマッチする**。
`docs/` 直下だけのつもりが `docs/**/*.md` 全件を拾い、置換の影響範囲が想定外に広がる。

- 意図した範囲か、実行前に `git ls-files <pathspec> | wc -l` で件数を確認する
- 直下のみに限定するなら `--` や `:(glob)` を使うか、`find -maxdepth 1` を使う

## 一括置換の前にファイルリストを確定させる

リネームと置換を同一ループで回すと、事前に確定したファイルリストがリネーム後のパスとズレて `No such file or directory` が多発する。

- **リネームを全件終えてから、改めてリストを取り直して置換する**の 2 段階に分ける

## シェルの作業ディレクトリはコマンド間で持続する

Bash ツールで `cd` すると、次のコマンド実行時もそのディレクトリのままになる。

- 原則として**絶対パスを使う**か、コマンド先頭でリポジトリルートへ `cd` する

## ce-shared-tools は .gitignore されており Grep の既定検索に出ない

`.gitignore` の `ce-shared-tools/` により、共通ツールとガイドライン一式が Grep (ripgrep ベース) の既定検索から除外される。
**存在しないのではなく、見えないだけ**である点に注意する。

共有 AI 向けガイドラインの正本は `ce-shared-tools/ai_docs/` 配下にある。確認・編集が必要な場合は、検索対象にこのディレクトリを明示する。

```bash
rg --files ce-shared-tools/ai_docs
```

### 回避策

- `ce-shared-tools/` 配下を探すときは **path を明示**して Grep する
- 全文横断で探したいときは Bash の `find` / `grep -r` を使う (gitignore を無視するため)
- ドキュメントから参照するときは**必ず明示パスで書く**。ファイル名だけ書くと AI が探索で辿り着けない

## ce-shared-tools のツールはルートに複製せず正本を呼ぶ

複製は置かず、正本だけをプロジェクトルートから実行する (未追跡の複製は消えたとき復元できない)。

```bash
bash ce-shared-tools/tools/bash/RunTool_MakeReadme.sh
bash ce-shared-tools/tools/bash/RunTool_GetToolsEnv.sh projecttype --default unity
```

- スクリプト内のパス解決は**カレントディレクトリ基準**のため、スクリプト自体の置き場所に関係なくプロジェクトルートから実行すれば動く
- ルートに複製を置くと `ce-shared-tools` 側の更新と二重管理になり、同期漏れが起きる

### CLAUDE.md の記述との差異に注意

AGENTS.md は `ce-shared-tools/ai_docs/2_instructions/*.inline.md` から生成される共有文書であり
(CLAUDE.md は `@AGENTS.md` の取り込み 1 行に固定。再生成は `RunTool_MakeRolePrompt.sh dev "" AGENTS.md` だけ)、
`RunTool_MakeReadme.sh` や `tools/bash/RunTool_GetToolsEnv.sh` のようにファイル名や短縮パスで書かれている。
これは ce-shared-tools リポジトリ自身を基準にした記述のため、**本リポジトリではそのままでは動かない**。
上記の明示パスに読み替えること。

## 破壊的な一括操作の前後で検証する

- 変更前に `dotnet test` のベースライン (成功数・失敗数) を取得しておく
- 変更後に同じコマンドを実行し、**数値が一致すること**をもって回帰なしと判断する
- 既知の失敗があるリポジトリでは「失敗 0 件」ではなくベースラインとの一致で判定する
