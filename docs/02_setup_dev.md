---
title: 開発環境セットアップ
description: プロジェクトの開発環境構築手順
seealso:
  - docs/00_docs_index.md
  - docs/03_ai_command_notes.md
---

# 開発環境セットアップ

プロジェクトの開発環境を構築する手順。

## 前提条件

### ソフトウェア

| ソフトウェア | バージョン | 備考 |
|------------|----------|------|
| | | |

## リポジトリの取得

```bash
git clone https://github.com/Yukuto-Matori/ce-sns-supporter.git
cd ce-sns-supporter
```

## プロジェクト構造

```text
ce-sns-supporter/
├── data/                    # SNS データ(x, insta, facebook, homepage などの各種データを格納)
├── build/                   # SNS Supporter のコードのビルド先
├── src/                     # SNS Supporter の機能をもつソースコード
├── docs/                    # プロジェクトドキュメント
├── ce-shared-tools/         # 共有ツール・AI 指示書
```

## 参考ドキュメント

- [ドキュメントインデックス](00_docs_index.md)
- [AI 向け作業注意事項](03_ai_command_notes.md)
