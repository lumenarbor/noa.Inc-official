#!/usr/bin/env bash
# =============================================================
# 本番デプロイ（Netlify CLI・build なし・functions 込み）
#
#   bash scripts/deploy-prod.sh <git-ref>
#   例) bash scripts/deploy-prod.sh redesign/v2
#
# このサイトは manual deploy（continuous deployment 未設定）。
# public/ は既にプリビルド済みの成果物なので、build は一切走らせず
# 「public/ + netlify/functions/ を直接本番へ載せる」だけでよい。
#
# build を誘発しない設計:
#  - `netlify deploy` は --build を付けない限り build を実行しない
#  - --dir にプリビルド済みパッケージを明示 → publish 設定の解決に依存しない
#  - --no-build を明示（UI 保存の build command への保険）
#
# Guard（2026-08-30 インシデント再発防止。詳細は docs/OPERATIONS.md）:
#   デプロイ前  R1 必須 function ソースの存在
#              R2 link 先が本番サイト（noa-place.co.jp）であること
#   デプロイ後  R3 deploy metadata に slack / notion-intake があること
#              R4 本番ランタイムが 405 を返すこと（HTML fallback を FAIL 扱い）
#   いずれか1つでも落ちれば non-zero exit する。
#
# 事前準備（初回のみ・要ブラウザ操作。※既に link 済みなら不要）:
#   npx --yes netlify-cli login
#   npx netlify-cli link          # 本番サイトを選択（.netlify/state.json 生成）
#   環境変数 SLACK_WEBHOOK_URL / NOTION_TOKEN / NOTION_INTAKE_DB_ID が
#   Netlify UI に設定済みであること
# =============================================================
set -euo pipefail

REF="${1:?git ref を指定してください (例: redesign/v2)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/prod-site.conf"
. "$HERE/lib/deploy-guards.sh"

ROOT="$(git rev-parse --show-toplevel)"
SHA="$(git rev-parse --short "$REF")"

# =============================================================
# PREFLIGHT（デプロイ前 Guard）
# =============================================================
echo "=============================================="
echo " PREFLIGHT  ref=$REF ($SHA)"
echo "=============================================="
PRE_FAIL=0

echo ""
echo "[R1] REQUIRED_FUNCTION_FILES"
# shellcheck disable=SC2086
assert_required_function_files "$SITE_ROOT/netlify/functions" $REQUIRED_FUNCTIONS || PRE_FAIL=1

echo ""
echo "[R2] SITE_IDENTITY"
LINKED_ID="$(fetch_linked_site_id "$SITE_ROOT")"
if [ -z "$LINKED_ID" ]; then
  assert_site_identity "" "" "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN" || PRE_FAIL=1
else
  FACTS="$(fetch_site_facts "$LINKED_ID")"
  assert_site_identity "$LINKED_ID" "$(printf '%s' "$FACTS" | cut -f2)" \
                       "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN" || PRE_FAIL=1
fi

if [ "$PRE_FAIL" -ne 0 ]; then
  echo "" >&2
  echo "PRODUCTION_DEPLOY_BLOCKED" >&2
  echo "上記の理由により本番デプロイを開始しませんでした。本番は無変更です。" >&2
  exit 1
fi
echo ""
echo "  → PREFLIGHT_PASS"

# =============================================================
# DEPLOY
# =============================================================
# 1) 静的パッケージを ref から決定論的に生成（純コピー・build なし）
echo ""
NOA_PACKAGE_MODE=production bash "$ROOT/noa-site/scripts/make-drop-package.sh" "$REF"
PKG="$(cat "$ROOT/noa-site/release/.last-package-path")"

# 2) build を走らせず、プリビルド済み --dir と functions を直接 deploy --prod
cd "$SITE_ROOT"
DEPLOY_JSON="$(mktemp)"
trap 'rm -f "$DEPLOY_JSON"' EXIT
npx --yes netlify-cli deploy --prod \
  --dir "$PKG" \
  --functions netlify/functions \
  --no-build \
  --json \
  --message "manual deploy (no build) ${REF} @ ${SHA}" > "$DEPLOY_JSON"

DEPLOY_ID="$(node -e 'try{const j=require(process.argv[1]);process.stdout.write(j.deploy_id||j.deployId||(j.deploy&&j.deploy.id)||"")}catch(e){}' "$DEPLOY_JSON")"
DEPLOY_URL="$(node -e 'try{const j=require(process.argv[1]);process.stdout.write(j.url||j.deploy_url||"")}catch(e){}' "$DEPLOY_JSON")"
echo ""
echo "🚀 deploy complete"
echo "   deploy_id : ${DEPLOY_ID:-(取得失敗)}"
echo "   url       : ${DEPLOY_URL:-$PROD_URL}"

# =============================================================
# POST DEPLOY VERIFICATION（R3 + R4）
# =============================================================
echo ""
# CDN 反映の揺らぎを吸収するため、失敗したら一度だけ待って再検証する
if bash "$HERE/verify-prod-deploy.sh" "$DEPLOY_ID"; then
  VERIFY_RC=0
else
  echo ""
  echo "  … 反映待ちの可能性があるため 15 秒後に再検証します"
  sleep 15
  if bash "$HERE/verify-prod-deploy.sh" "$DEPLOY_ID"; then VERIFY_RC=0; else VERIFY_RC=1; fi
fi

if [ "$VERIFY_RC" -ne 0 ]; then
  echo "" >&2
  echo "PRODUCTION_DEPLOY_VERIFICATION_FAILED" >&2
  echo "デプロイは実行されましたが、検証に失敗しました。" >&2
  echo "Netlify の Deploys 画面から直前の正常なデプロイを Publish して切り戻してください。" >&2
  exit 1
fi

# 検証 PASS。警告ラベルの無い本番用パッケージを release/ に残さない。
# （人が後からブラウザへドラッグできる無印フォルダを消す = 事故経路を断つ。
#   同じ ref から決定論的に再生成できるので、保持する必要はない）
rm -rf "$PKG" "$ROOT/noa-site/release/.last-package-path"

echo ""
echo "=== 残りの手動確認 ==="
echo "1) 静的内容: curl -s $PROD_URL/deploy-info.json"
echo "   → commit が $(git rev-parse "$REF") と一致すること"
echo "2) 実通知  : 本番フォームからテスト送信1件 → Slack 受信 + Notion 登録を確認"
echo "3) 台帳    : git tag deploy/\$(date +%Y-%m-%d)-n $REF && docs/DEPLOY-LOG.md に追記"
