#!/usr/bin/env bash
# =============================================================
# 本番デプロイ検証（単体で実行可能）
#
#   bash scripts/verify-prod-deploy.sh
#
# これ1本で以下を確認する:
#   1. Site identity        … link 先が noa-place.co.jp の本番サイトか
#   2. Deployed functions   … 本番 deploy metadata に slack / notion-intake があるか
#   3. Webhook path health  … Outgoing Webhook が実際に叩く /hooks/* が 405 を返すか
#   4. Alias fallback       … 未定義の /hooks/* が 4xx になるか（200 を返さないこと）
#   5. Internal endpoints   … /.netlify/functions/* も 405 を返すか（内部健全性）
#   6. HTML fallback 検知   … 200 + text/html（= function 未配備）を FAIL にする
#   7. Webhook configuration… Netlify Forms の Outgoing Webhook が alias URL を
#                             向いているか（UI から旧 direct path へ戻されたら FAIL）
#
# すべて read-only。Netlify の設定を書き換える処理は含まない。
#
# deploy-prod.sh からデプロイ直後にも呼ばれる。
# GET しか行わないため、本番の問い合わせデータを生成することはない。
# secret は一切出力しない。
# =============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=./prod-site.conf
. "$HERE/prod-site.conf"
# shellcheck source=./lib/deploy-guards.sh
. "$HERE/lib/deploy-guards.sh"

# 特定 deploy を検証したい場合は第1引数に deploy_id（省略時は現在の公開デプロイ）
TARGET_DEPLOY="${1:-}"

FAIL=0
echo "=============================================="
echo " 本番デプロイ検証  ($PROD_URL)"
echo "=============================================="

# ---- 1. Site identity ------------------------------------------------
echo ""
echo "[1/6] SITE_IDENTITY"
LINKED_ID="$(fetch_linked_site_id "$SITE_ROOT")"
FACTS="$(fetch_site_facts "${LINKED_ID:-$PROD_SITE_ID}")"
ACTUAL_ID="$(printf '%s' "$FACTS" | cut -f1)"
ACTUAL_DOMAIN="$(printf '%s' "$FACTS" | cut -f2)"
PUBLISHED_FNS="$(printf '%s' "$FACTS" | cut -f3)"
assert_site_identity "${LINKED_ID:-$ACTUAL_ID}" "$ACTUAL_DOMAIN" "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN" || FAIL=1

# ---- 2. Deployed functions (metadata) --------------------------------
echo ""
echo "[2/6] DEPLOYED_FUNCTIONS (Netlify deploy metadata)"
if [ -n "$TARGET_DEPLOY" ]; then
  DEPLOYED_FNS="$(fetch_deploy_functions "$TARGET_DEPLOY")"
  echo "  対象 deploy_id: $TARGET_DEPLOY"
else
  DEPLOYED_FNS="$PUBLISHED_FNS"
  echo "  対象: 現在の公開デプロイ"
fi
# shellcheck disable=SC2086
assert_deployed_functions "$DEPLOYED_FNS" $REQUIRED_FUNCTIONS || FAIL=1

# ---- 3. Webhook path health（Outgoing Webhook が実際に叩くパス）--------
# 直接 /.netlify/functions/* を叩くと、function 未配備時に SPA catch-all が
# 200 + index.html を返してしまう（予約名前空間には redirect を書けない）。
# Webhook は /hooks/* を経由するので、まずそちらを主判定にする。
echo ""
echo "[3/6] WEBHOOK_PATHS (Outgoing Webhook が叩く公開パス)"
for wp in $WEBHOOK_PATHS; do
  R="$(probe_endpoint "$PROD_URL$wp")"
  assert_runtime_endpoint "$wp" "$(printf '%s' "$R" | cut -f1)" "$(printf '%s' "$R" | cut -f2)" || FAIL=1
done

# ---- 4. Alias fallback（未定義 hook が 200 を返さないこと）--------------
echo ""
echo "[4/6] ALIAS_FALLBACK (未定義 hook は 4xx であること)"
R="$(probe_endpoint "$PROD_URL/hooks/__nonexistent__")"
FB_STATUS="$(printf '%s' "$R" | cut -f1)"
FB_CTYPE="$(printf '%s' "$R" | cut -f2)"
case "$FB_STATUS" in
  4*) guard_pass "/hooks/__nonexistent__: $FB_STATUS (${FB_CTYPE%%;*})" ;;
  *)  guard_fail "ALIAS_FALLBACK_BROKEN: /hooks/__nonexistent__ expected 4xx, got $FB_STATUS ${FB_CTYPE%%;*} — SPA catch-all に吸われています"; FAIL=1 ;;
esac

# ---- 5. Internal endpoints（内部健全性）--------------------------------
echo ""
echo "[5/6] INTERNAL_FUNCTION_PATHS (直接エンドポイントの健全性)"
for ip in $INTERNAL_FUNCTION_PATHS; do
  R="$(probe_endpoint "$PROD_URL$ip")"
  assert_runtime_endpoint "$ip" "$(printf '%s' "$R" | cut -f1)" "$(printf '%s' "$R" | cut -f2)" || FAIL=1
done

# ---- 6. Webhook configuration（Netlify UI 側の設定監査・read-only）------
# alias route が生きていても、Webhook が旧 direct path を向いていたら意味がない。
# ここまでの Gate では検知できないため、設定そのものを突き合わせる。
echo ""
echo "[6/6] WEBHOOK_CONFIGURATION (Netlify Forms の Outgoing Webhook 設定)"
HOOKS_TSV="$(fetch_hooks_tsv "${LINKED_ID:-$PROD_SITE_ID}")"
if [ -z "$HOOKS_TSV" ]; then
  guard_fail "WEBHOOK_CONFIGURATION_MISMATCH: hook 設定を取得できませんでした（netlify login / 権限を確認）"
  FAIL=1
else
  assert_webhook_configuration "$HOOKS_TSV" "$EXPECTED_FORM_NAME" \
    "$EXPECTED_SLACK_WEBHOOK_URL" "$EXPECTED_NOTION_WEBHOOK_URL" || FAIL=1
fi

echo ""
echo "=============================================="
if [ "$FAIL" -eq 0 ]; then
  echo " ALL_GATES_PASS"
  echo "=============================================="
  exit 0
fi
echo " PRODUCTION_DEPLOY_VERIFICATION_FAILED" >&2
echo "==============================================" >&2
echo "" >&2
echo " 復旧手順: bash scripts/deploy-prod.sh <git-ref>" >&2
echo " （ブラウザからの folder ドロップは Functions を配備しないため使用禁止）" >&2
exit 1
