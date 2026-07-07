# 本番デプロイ台帳

ルール: 本番（noa-place.co.jp）へ Drop するたびに1行追記し、`deploy/YYYY-MM-DD-n` タグを打つ。
実体確認: `curl https://noa-place.co.jp/deploy-info.json`

| 日付 | タグ | commit | ref | 内容 | 確認者 |
|---|---|---|---|---|---|
| （例）2026-07-XX | deploy/2026-07-XX-1 | 6a33144 | redesign/v2 | Phase 1: ローダー短縮/モバイルCTA/フォーム改善/遷移v2 | |

※ 2026-07-07 時点の本番は Netlify Drop による手動反映（deploy-info.json なしの世代）。
   baseline 相当 = tag `baseline-v1-2026-07-07`（commit e75e7ee）。
