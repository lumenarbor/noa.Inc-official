#!/usr/bin/env bash
# =============================================================
# 本番デプロイ検証（単体で実行可能）
#
#   bash scripts/verify-prod-deploy.sh
#
# これ1本で以下を確認する:
#   1. Site identity        … link 先が noa-place.co.jp の本番サイトか
#   2. Deployed functions   … 本番 deploy metadata に slack / notion-intake があるか
#   3. Runtime health       … 両エンドポイントが 405 を返すか
#   4. HTML fallback 検知   … 200 + text/html（= function 未配備）を FAIL にする
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
echo "[1/3] SITE_IDENTITY"
LINKED_ID="$(fetch_linked_site_id "$SITE_ROOT")"
FACTS="$(fetch_site_facts "${LINKED_ID:-$PROD_SITE_ID}")"
ACTUAL_ID="$(printf '%s' "$FACTS" | cut -f1)"
ACTUAL_DOMAIN="$(printf '%s' "$FACTS" | cut -f2)"
PUBLISHED_FNS="$(printf '%s' "$FACTS" | cut -f3)"
assert_site_identity "${LINKED_ID:-$ACTUAL_ID}" "$ACTUAL_DOMAIN" "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN" || FAIL=1

# ---- 2. Deployed functions (metadata) --------------------------------
echo ""
echo "[2/3] DEPLOYED_FUNCTIONS (Netlify deploy metadata)"
if [ -n "$TARGET_DEPLOY" ]; then
  DEPLOYED_FNS="$(fetch_deploy_functions "$TARGET_DEPLOY")"
  echo "  対象 deploy_id: $TARGET_DEPLOY"
else
  DEPLOYED_FNS="$PUBLISHED_FNS"
  echo "  対象: 現在の公開デプロイ"
fi
# shellcheck disable=SC2086
assert_deployed_functions "$DEPLOYED_FNS" $REQUIRED_FUNCTIONS || FAIL=1

# ---- 3. Runtime health ------------------------------------------------
echo ""
echo "[3/3] RUNTIME (safe GET / 405 期待・HTML fallback 検知)"
for fn in $REQUIRED_FUNCTIONS; do
  R="$(probe_endpoint "$PROD_URL/.netlify/functions/$fn")"
  assert_runtime_endpoint "$fn" "$(printf '%s' "$R" | cut -f1)" "$(printf '%s' "$R" | cut -f2)" || FAIL=1
done

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
