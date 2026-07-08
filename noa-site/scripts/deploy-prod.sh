#!/usr/bin/env bash
# =============================================================
# 本番デプロイ（Netlify CLI・functions込み）
#
# 背景: ブラウザの Netlify Drop は静的ファイルしか配備できず、
# netlify/functions/slack.js（フォームのSlack通知）が本番に
# 存在しない状態が発生していた。本番反映はこのスクリプトで行う。
# （ブラウザDropは比較プレビュー用途に限定する）
#
# 事前準備（初回のみ・要ブラウザ操作）:
#   cd noa-site
#   npx --yes netlify-cli login    # ブラウザで認証
#   npx netlify-cli link           # 本番サイトを選択して紐付け
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

# 1) 静的パッケージを従来どおり ref から決定論的に生成
bash "$ROOT/noa-site/scripts/make-drop-package.sh" "$REF"

# 2) CLI で本番へ（--functions で slack.js を同梱）
cd "$ROOT/noa-site"
npx --yes netlify-cli deploy --prod \
  --dir "$PKG" \
  --functions netlify/functions \
  --message "deploy ${REF} @ ${SHA}"

echo ""
echo "=== デプロイ後の検証 ==="
echo "1) 静的内容:   curl -s https://noa-place.co.jp/deploy-info.json"
echo "   → commit が $(git rev-parse "$REF") と一致すること"
echo "2) function:  curl -s -o /dev/null -w '%{http_code}' https://noa-place.co.jp/.netlify/functions/slack"
echo "   → 405 なら配備成功（POST以外拒否のガード応答）"
echo "   → 200 が返る場合は index.html が返っており未配備"
echo "3) 実通知:    本番フォームからテスト送信1件 → Slack 受信確認"
