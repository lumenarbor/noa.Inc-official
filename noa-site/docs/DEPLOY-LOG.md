# 本番デプロイ台帳

ルール: 本番（noa-place.co.jp）へデプロイするたびに1行追記し、`deploy/YYYY-MM-DD-n` タグを打つ。
本番デプロイは `bash scripts/deploy-prod.sh <ref>` のみ（ブラウザからのフォルダドロップは禁止）。
実体確認: `curl https://noa-place.co.jp/deploy-info.json` / `bash scripts/verify-prod-deploy.sh`

| 日付 | タグ | commit | ref | 内容 | 確認者 |
|---|---|---|---|---|---|
| （例）2026-07-XX | deploy/2026-07-XX-1 | 6a33144 | redesign/v2 | Phase 1: ローダー短縮/モバイルCTA/フォーム改善/遷移v2 | |
| 2026-07-30 | | f10d0f5 | redesign/v2 | deploy-prod.sh。functions 2件配備（最後の正常デプロイ） | |
| 2026-08-30 | | 328a92f→a91314b | redesign/v2 | ⚠️ static-only デプロイ4件。**Functions 消失 → Slack/Notion 通知停止（9/4 まで無検知）** | |
| 2026-09-04 | | a91314b | redesign/v2 | 復旧デプロイ（deploy-prod.sh）。functions 2件再配備・405 確認・E2E PASS。取りこぼし1件は Notion へ Backfill 済み | |
| 2026-09-04 | | f6631f0 | redesign/v2 | Webhook 用エイリアス `/hooks/*` を追加。Outgoing Webhook を direct function path から alias へ移行し、未配備時に 200 ではなく 4xx を返す構成へ。E2E 2件 PASS | |
| 2026-09-04 | | 702f2eb | redesign/v2 | HPフォームの会社名を Notion「会社名」へ保存。deploy id `6a9aa17a2fe53b080743810b` / 6 Gate ALL_PASS / E2E PASS | |

※ 2026-07-07 時点の本番は Netlify Drop による手動反映（deploy-info.json なしの世代）。
   baseline 相当 = tag `baseline-v1-2026-07-07`（commit e75e7ee）。

## インシデント記録

- **2026-07-08** ブラウザ Drop により slack function が消失 → Slack 通知停止。CLI デプロイへ運用変更。
- **2026-08-30 〜 2026-09-04** 再発。static-only デプロイにより slack / notion-intake が同時消失。
  Netlify Forms のメール通知のみ生存したため約5日間無検知。障害期間中の問い合わせ1件を取りこぼし、
  2026-09-04 に Notion へ Backfill。同日 `scripts/` に Deployment Guard を導入し、
  同種事故を機械的に検知・阻止できるようにした（詳細は `docs/OPERATIONS.md`）。
  さらに Outgoing Webhook を `/hooks/*` エイリアスへ移行し、Function 未配備時に
  200 ではなく 4xx が返る構成にしたうえで、Webhook 設定そのものを検査する
  Gate を追加した。

  **Incident Status: CLOSED（2026-09-04）**
  最終状態: 本番 commit `702f2eb` / `bash scripts/verify-prod-deploy.sh` が 6/6 ALL_GATES_PASS /
  Netlify Forms・メール・Slack・Notion の4経路すべて本番 E2E 済み。
  以降に残る項目（日次自動実行、Netlify UI からの直接 Publish、Notion の Update 権限、
  既存レコードの会社名 Backfill 等）はインシデントの未完了事項ではなく、
  通常のバックログ／受容済みの制約として扱う。
