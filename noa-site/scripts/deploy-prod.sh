#!/usr/bin/env bash
# =============================================================
# 本番デプロイ（Netlify CLI・build なし・functions 込み）
#
# このサイトは manual deploy（continuous deployment 未設定）。
# public/ は既にプリビルド済みの成果物なので、build は一切走らせず
# 「public/ + netlify/functions/ を直接本番へ載せる」だけでよい。
#
# build を誘発しない設計:
#  - `netlify deploy` は --build を付けない限り build を実行しない
#    （build を走らせるのは `netlify build` / `deploy --build` のみ）
#  - --dir にプリビルド済みパッケージを明示 → publish 設定の解決に依存しない
#  - --skip-functions-cache で zisi キャッシュ由来の再処理も避ける
#  ※ UI 保存の build command が state に継承されていても、
#    deploy サブコマンド単体では発火しない。
#
# 事前準備（初回のみ・要ブラウザ操作。※既に link 済みなら不要）:
#   cd noa-site
#   npx --yes netlify-cli login
#   npx netlify-cli link          # 本番サイトを選択（.netlify/state.json 生成）
#   環境変数 SLACK_WEBHOOK_URL が Netlify UI に設定済みであること
#
# 使い方:
#   bash scripts/deploy-prod.sh <git-ref>
#   例) bash scripts/deploy-prod.sh redesign/v2
# =============================================================
set -euo pipefail

REF="${1:?git ref を指定してください (例: redesign/v2)}"
ROOT="$(git rev-parse --show-toplevel)"
SHA="$(git rev-parse --short "$REF")"
DATE="$(date +%Y-%m-%d)"
NAME="noa-drop_${DATE}_${REF//\//-}_${SHA}"
PKG="$ROOT/noa-site/release/$NAME"

# 1) 静的パッケージを ref から決定論的に生成（純コピー・build なし）
bash "$ROOT/noa-site/scripts/make-drop-package.sh" "$REF"

# 2) build を走らせず、プリビルド済み --dir と functions を直接 deploy --prod
#    --dir      : プリビルド済み成果物を明示（build 出力を待たない）
#    --functions: netlify/functions を同梱（slack.js を配備）
#    --no-build : build ステップを明示的に無効化（保険）
cd "$ROOT/noa-site"
npx --yes netlify-cli deploy --prod \
  --dir "$PKG" \
  --functions netlify/functions \
  --no-build \
  --message "manual deploy (no build) ${REF} @ ${SHA}"

echo ""
echo "=== デプロイ後の検証 ==="
echo "1) 静的内容:   curl -s https://noa-place.co.jp/deploy-info.json"
echo "   → commit が $(git rev-parse "$REF") と一致すること"
echo "2) function:  curl -s -o /dev/null -w '%{http_code}\\n' https://noa-place.co.jp/.netlify/functions/slack"
echo "   → 405 なら配備成功（POST以外拒否のガード応答）"
echo "   → 200 が返る場合は index.html が返っており未配備"
echo "3) 実通知:    本番フォームからテスト送信1件 → Slack 受信確認"
