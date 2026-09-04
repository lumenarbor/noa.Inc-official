#!/usr/bin/env bash
# =============================================================
# デプロイ Guard の回帰テスト
#
#   bash scripts/test/deploy-guard-tests.sh
#
# 2026-08-30 のインシデント（本番へ static-only アーティファクトが投入され
# slack / notion-intake が消失）を、実際のデプロイを一切行わずに再現し、
# 新しい Guard が確実に FAIL させることを検証する。
#
# ネットワークにも Netlify API にも触れない:
#   deploy-guards.sh の判定関数は引数だけで結論を出す純関数なので、
#   fixture を直接渡せば全分岐を再現できる。
# =============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/deploy-guards.sh"
. "$HERE/../prod-site.conf"

PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# expect <期待rc> <ケース名> -- <コマンド...>
expect() {
  local want="$1" name="$2"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then
    printf '  ✅ %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  ❌ %s  (expected rc=%s, got rc=%s)\n' "$name" "$want" "$rc"
    printf '%s\n' "$out" | sed 's/^/       /'
    FAIL=$((FAIL+1))
  fi
}

echo "=============================================="
echo " Deployment Guard regression tests"
echo "=============================================="
echo ""

# ---- CASE 1: 必須 function ファイルが欠落 → preflight FAIL ----
mkdir -p "$TMP/fn_full" "$TMP/fn_partial" "$TMP/fn_empty"
: > "$TMP/fn_full/slack.js";    : > "$TMP/fn_full/notion-intake.js"
: > "$TMP/fn_partial/slack.js"
echo "CASE 1  required function file missing → FAIL"
expect 1 "notion-intake.js が無い → non-zero" -- assert_required_function_files "$TMP/fn_partial" slack notion-intake
expect 1 "1つも無い → non-zero"               -- assert_required_function_files "$TMP/fn_empty"   slack notion-intake
expect 0 "両方ある → PASS"                    -- assert_required_function_files "$TMP/fn_full"    slack notion-intake

# ---- CASE 2: site identity mismatch → FAIL ----
echo ""
echo "CASE 2  site identity mismatch → FAIL"
expect 1 "別サイトの site_id → non-zero"  -- assert_site_identity "other-site-id" "noa-place.co.jp" "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN"
expect 1 "domain 不一致 → non-zero"       -- assert_site_identity "$PROD_SITE_ID" "simplecareer.jp" "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN"
expect 1 "未link（site_id 空）→ non-zero" -- assert_site_identity "" "" "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN"
expect 1 "custom_domain 未設定 → non-zero" -- assert_site_identity "$PROD_SITE_ID" "" "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN"
expect 0 "本番サイト一致 → PASS"           -- assert_site_identity "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN" "$PROD_SITE_ID" "$PROD_CUSTOM_DOMAIN"

# ---- CASE 3: deploy metadata に両方あり → PASS ----
echo ""
echo "CASE 3  deploy metadata: slack + notion-intake → PASS"
expect 0 "両方あり → PASS"          -- assert_deployed_functions "notion-intake slack" slack notion-intake
expect 0 "順序が違っても PASS"      -- assert_deployed_functions "slack notion-intake" slack notion-intake

# ---- CASE 4: deploy metadata が片方だけ → FAIL ----
echo ""
echo "CASE 4  deploy metadata: slack only → FAIL"
expect 1 "slack のみ → non-zero"                    -- assert_deployed_functions "slack" slack notion-intake
expect 1 "notion-intake のみ → non-zero"            -- assert_deployed_functions "notion-intake" slack notion-intake
expect 1 "空（static-only デプロイ）→ non-zero"     -- assert_deployed_functions "" slack notion-intake
expect 1 "部分一致で誤判定しない (slack-old)"       -- assert_deployed_functions "slack-old notion-intake" slack notion-intake

# ---- CASE 5: runtime 405 text/plain → PASS ----
echo ""
echo "CASE 5  runtime: 405 text/plain → PASS"
expect 0 "slack 405 → PASS"          -- assert_runtime_endpoint "slack" "405" "text/plain; charset=utf-8"
expect 0 "notion-intake 405 → PASS"  -- assert_runtime_endpoint "notion-intake" "405" "text/plain; charset=utf-8"

# ---- CASE 6: runtime 200 text/html → FAIL（2026-08-30 の事故状態） ----
echo ""
echo "CASE 6  runtime: 200 text/html (=SPA fallback) → FAIL"
expect 1 "200 + text/html → non-zero"        -- assert_runtime_endpoint "slack" "200" "text/html; charset=UTF-8"
expect 1 "405 でも text/html なら non-zero"  -- assert_runtime_endpoint "slack" "405" "text/html; charset=UTF-8"

# ---- CASE 7: runtime 404 → FAIL ----
echo ""
echo "CASE 7  runtime: 404 → FAIL"
expect 1 "404 → non-zero"                 -- assert_runtime_endpoint "notion-intake" "404" "text/plain"
expect 1 "500 → non-zero"                 -- assert_runtime_endpoint "slack" "500" "text/plain"
expect 1 "000（到達不能）→ non-zero"      -- assert_runtime_endpoint "slack" "000" ""

# ---- 構造テスト: preview スクリプトに --prod が存在しないこと ----
echo ""
echo "CASE 8  deploy-preview.sh に実行フラグとしての --prod が無いこと"
if grep -n -- '--prod' "$HERE/../deploy-preview.sh" | grep -qv '^[0-9]*:#'; then
  printf '  ❌ deploy-preview.sh にコメント以外の --prod があります\n'; FAIL=$((FAIL+1))
else
  printf '  ✅ コメント以外に --prod なし\n'; PASS=$((PASS+1))
fi

# ---- 構造テスト: 本番デプロイ経路が --functions を必ず含むこと ----
echo ""
echo "CASE 9  deploy-prod.sh が --functions を含むこと"
if grep -q -- '--functions netlify/functions' "$HERE/../deploy-prod.sh"; then
  printf '  ✅ --functions netlify/functions あり\n'; PASS=$((PASS+1))
else
  printf '  ❌ --functions が欠落（static-only デプロイになる）\n'; FAIL=$((FAIL+1))
fi

echo ""
echo "=============================================="
printf ' PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
echo " ALL_TESTS_PASS"
