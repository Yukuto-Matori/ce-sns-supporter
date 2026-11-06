# briefs (依頼書)

Coordinator セッションが Worker セッションへ渡す依頼書の置き場所。

- ファイル名 (拡張子を除く) = `todo-plan.yaml` のタスク ID。これが紐づけそのもの
- 完了した依頼書は `done/` へ移動する。`done/` は起動概要の走査対象外
- 未完了の依頼書は `todo-plan.active.md` の `## Open Briefs` 節へ自動で載る

書式と運用ルール: `ce-shared-tools/ai_docs/3_references/Guideline_ManageWorkBrief.md`
