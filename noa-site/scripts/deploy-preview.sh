#!/usr/bin/env bash
# =============================================================
# 比較プレビュー用デプロイ（draft deploy・本番は一切変更しない）
#
#   bash scripts/deploy-preview.sh <git-ref> [alias]
#   例) bash scripts/deploy-preview.sh redesign/v2
#   例) bash scripts/deploy-preview.sh redesign/v2 hero-v3
#
# 仕組み:
#   netlify-cli の `deploy` は --prod を付けない限り draft deploy になる
#   （CLI v26 のヘルプ: "Creates a draft deploy by default.
#     Use --prod to deploy directly to your live site."）
#   draft deploy は一意の Preview URL を発行するだけで、
#   公開デプロイ（noa-place.co.jp が指すデプロイ）を置き換えない。
#
# 本番デプロイとの違いは --prod の有無だけなので、
#   - publish source の生成方式は本番と同一（make-drop-package.sh）
#   - Functions も同梱（本番と同じ挙動をプレビューで確認できる）
# となり、「プレビューでは動いたのに本番で動かない」を構造的に潰せる。
#
# 旧運用（release フォルダを app.netlify.com/drop や本番 Deploys 画面へ
# ドラッグする方法）はこのスクリプトで置き換える。ドロップ運用は
# 静的ファイルしか配備できず、本番へ投入すると Functions が消失する。
#
# ⚠️ PREVIEW の限界（2026-09-04 実測で判明）:
#   CLI の draft deploy は context = branch-deploy で動く。
#   本番の環境変数（NOTION_TOKEN 等）はこの context の function ランタイムへ
#   届かないため、function は env missing 分岐に入る。
#   つまり preview で確認できるのは
#     - routing（/hooks/* の rewrite、404 フォールバック、SPA fallback）
#     - static content
#     - function が deploy に含まれているか（GET で 405 が返るか）
#   までであり、Notion 書き込み / Slack 投稿 / business logic の E2E は
#   本番同等ではない。
#   preview へ POST すると notion-intake が env missing 分岐に入り、
#   Slack へ「⚠️ 設定エラー」の警告が飛ぶ（2026-09-04 に実際に発生）。
#   → preview では POST しないこと。E2E は本番フォームで行う。
#   → 本番の秘密情報を branch-deploy へコピーして解決してはならない。
# =============================================================
set -euo pipefail

REF="${1:?git ref を指定してください (例: redesign/v2)}"
ALIAS_RAW="${2:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/prod-site.conf"
. "$HERE/lib/deploy-guards.sh"

ROOT="$(git rev-parse --show-toplevel)"
SHA="$(git rev-parse --short "$REF")"

# --prod が紛れ込む余地をなくすため、引数はここで固定的に組み立てる
if [ -n "$ALIAS_RAW" ]; then
  # Netlify の alias 制約（37文字以内・英数とハイフン）に丸める
  ALIAS="$(printf '%s' "$ALIAS_RAW" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | cut -c1-37)"
else
  ALIAS="$(printf 'preview-%s-%s' "${REF//\//-}" "$SHA" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | cut -c1-37)"
fi

echo "=============================================="
echo " PREVIEW DEPLOY (draft / 本番は変更しません)"
echo " ref=$REF ($SHA)  alias=$ALIAS"
echo "=============================================="
echo ""
echo "  PREVIEW LIMITATION:"
echo "    Function routing can be tested."
echo "    Production secrets are not available in branch-deploy."
echo "    Do not use preview POST requests for Slack/Notion E2E."
echo ""

# 本番サイトへ draft を作るので、link 先が想定どおりかは確認する。
# ただし確認するだけで、本番デプロイは行わない。
echo ""
echo "[check] SITE_IDENTITY (確認のみ・本番反映はしません)"
LINKED_ID="$(fetch_linked_site_id "$SITE_ROOT")"
if [ -z "$LINKED_ID" ]; then
  assert_site_identity "" "" "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN" || true
  echo "" >&2
  echo "PREVIEW_DEPLOY_BLOCKED: Netlify サイトが未linkです。npx netlify-cli link を実行してください。" >&2
  exit 1
fi
FACTS="$(fetch_site_facts "$LINKED_ID")"
if ! assert_site_identity "$LINKED_ID" "$(printf '%s' "$FACTS" | cut -f2)" "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN"; then
  echo "" >&2
  echo "PREVIEW_DEPLOY_BLOCKED: SITE_IDENTITY_MISMATCH" >&2
  exit 1
fi

# publish source は本番と同じ生成方式（コミット済み ref から決定論的に生成）
echo ""
bash "$ROOT/noa-site/scripts/make-drop-package.sh" "$REF"
PKG="$(cat "$ROOT/noa-site/release/.last-package-path")"

cd "$SITE_ROOT"
# ★ --prod は付けない。付けないことが draft deploy の条件。
npx --yes netlify-cli deploy \
  --dir "$PKG" \
  --functions netlify/functions \
  --no-build \
  --alias "$ALIAS" \
  --message "preview (no build) ${REF} @ ${SHA}"

echo ""
echo "=============================================="
echo " 本番 ($PROD_URL) は変更されていません。"
echo "=============================================="
echo "上に表示された Website Draft URL が比較用の Preview URL です。"
echo ""
echo "旧新の切替比較（同一デプロイ内でフラグ切替）:"
echo "  <preview-url>/?flags=loader:v1,transitions:v1,stickyCta:off,ctaLanes:off,formPlus:off"
echo ""
echo "本番へ反映する場合: bash scripts/deploy-prod.sh $REF"
