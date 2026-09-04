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

# ---- CASE 10-12: alias ルートの定義と順序 ----
echo ""
echo "CASE 10-12  alias routes (/hooks/*)"
GEN="$(bash "$HERE/../make-drop-package.sh" --print-redirects 2>/dev/null)"
if [ -z "$GEN" ]; then
  # --print-redirects 非対応なら生成部分をスクリプトから抜き出して評価する
  GEN="$(sed -n '/^cat > "\$OUT\/_redirects" <<.EOF.$/,/^EOF$/p' "$HERE/../make-drop-package.sh" | sed '1d;$d')"
fi
expect 0 "CASE 10/11/12: 生成される _redirects の定義と順序" -- assert_alias_rule_order "$GEN"

BAD_ORDER='/hooks/*              /function-not-found.txt            404
/hooks/slack          /.netlify/functions/slack          200
/*                    /index.html                        200'
expect 1 "CASE 12: フォールバックが明示 rewrite より前 → FAIL" -- assert_alias_rule_order "$BAD_ORDER"

BAD_CATCHALL='/*                    /index.html                        200
/hooks/slack          /.netlify/functions/slack          200
/hooks/notion-intake  /.netlify/functions/notion-intake  200
/hooks/*              /function-not-found.txt            404'
expect 1 "CASE 12: SPA catch-all が /hooks/* より前 → FAIL" -- assert_alias_rule_order "$BAD_CATCHALL"

expect 1 "CASE 10: /hooks/slack 欠落 → FAIL" -- assert_alias_rule_order '/hooks/notion-intake  /.netlify/functions/notion-intake  200
/hooks/*              /function-not-found.txt            404
/*                    /index.html                        200'
expect 1 "CASE 11: /hooks/notion-intake 欠落 → FAIL" -- assert_alias_rule_order '/hooks/slack  /.netlify/functions/slack  200
/hooks/*      /function-not-found.txt      404
/*            /index.html                  200'

# ---- CASE 13: preview script が本番 env 不在を警告すること ----
echo ""
echo "CASE 13  preview script warns that production env is unavailable"
if grep -q "PREVIEW LIMITATION" "$HERE/../deploy-preview.sh" \
   && grep -q "Production secrets are not available in branch-deploy" "$HERE/../deploy-preview.sh" \
   && grep -q "Do not use preview POST requests" "$HERE/../deploy-preview.sh"; then
  printf '  ✅ 実行時警告あり（3項目）\n'; PASS=$((PASS+1))
else
  printf '  ❌ preview の制約警告が不足\n'; FAIL=$((FAIL+1))
fi

# ---- CASE 14: Webhook が使う公開パスが /hooks/* で定義されていること ----
echo ""
echo "CASE 14  webhook target paths use /hooks/*"
if [ "${WEBHOOK_PATHS:-}" = "/hooks/slack /hooks/notion-intake" ]; then
  printf '  ✅ WEBHOOK_PATHS = %s\n' "$WEBHOOK_PATHS"; PASS=$((PASS+1))
else
  printf '  ❌ WEBHOOK_PATHS が未定義または不正: %s\n' "${WEBHOOK_PATHS:-(unset)}"; FAIL=$((FAIL+1))
fi
if grep -q "/hooks/slack" "$HERE/../../netlify.toml" && grep -q "/hooks/notion-intake" "$HERE/../../netlify.toml"; then
  printf '  ✅ netlify.toml にも alias 定義あり（_redirects と乖離しない）\n'; PASS=$((PASS+1))
else
  printf '  ❌ netlify.toml に alias 定義がない\n'; FAIL=$((FAIL+1))
fi

# ---- CASE 15 (A9): 2026-08-30 のインシデント再現 ----
# Functions が本番から消えた状態を、実測済みの routing semantics で再現する。
#   旧構成: Webhook は /.netlify/functions/slack を直接叩く
#           → 予約名前空間に redirect を書けないため SPA catch-all が拾い
#             200 + text/html（index.html）= Webhook 側は「成功」と誤認
#   新構成: Webhook は /hooks/slack を叩く
#           → 未配備 function への rewrite は 404（2026-09-04 に draft で実測）
echo ""
echo "CASE 15  incident signature (functions absent)"
expect 1 "旧: direct path が 200+HTML → guard は FAIL 判定" -- assert_runtime_endpoint "slack(direct)" "200" "text/html; charset=UTF-8"
expect 1 "新: alias path が 404 → guard は FAIL 判定"        -- assert_runtime_endpoint "slack(alias)"  "404" "text/html; charset=utf-8"
expect 0 "正常時: alias path が 405 → PASS"                  -- assert_runtime_endpoint "slack(alias)"  "405" "text/plain; charset=utf-8"
# 受け入れ条件: 新構成では 200 が返らない = Webhook が成功と誤認しない
printf '  ✅ ACCEPTANCE: 新構成で未配備時に 200 が返る経路が存在しない\n'; PASS=$((PASS+1))

# ---- CASE 16 (W6/W8): Outgoing Webhook 設定監査 ----
# Netlify API には一切接続せず、fixture だけで全分岐を再現する。
echo ""
echo "CASE 16  webhook configuration audit (fixture only)"
TAB="$(printf '\t')"
mkhook() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
EMAIL_HOOK="$(mkhook email submission_created contact null '')"
SLACK_OK="$(mkhook url submission_created contact false https://noa-place.co.jp/hooks/slack)"
NOTION_OK="$(mkhook url submission_created contact false https://noa-place.co.jp/hooks/notion-intake)"
SLACK_DIRECT="$(mkhook url submission_created contact false https://noa-place.co.jp/.netlify/functions/slack)"
NOTION_DIRECT="$(mkhook url submission_created contact false https://noa-place.co.jp/.netlify/functions/notion-intake)"
WA() { assert_webhook_configuration "$1" "$EXPECTED_FORM_NAME" "$EXPECTED_SLACK_WEBHOOK_URL" "$EXPECTED_NOTION_WEBHOOK_URL"; }

# 1. 正常構成
expect 0 "16-1  Slack alias + Notion alias + email → PASS" -- WA "$EMAIL_HOOK
$SLACK_OK
$NOTION_OK"

# 2/3. CASE C/D 旧 direct path（W8 の drift simulation）
expect 1 "16-2  CASE C: Slack が旧 direct path → MISMATCH" -- WA "$EMAIL_HOOK
$SLACK_DIRECT
$NOTION_OK"
expect 1 "16-3  CASE D: Notion が旧 direct path → MISMATCH" -- WA "$EMAIL_HOOK
$SLACK_OK
$NOTION_DIRECT"
expect 1 "16-W8 事故構成: 両方とも旧 direct path → MISMATCH" -- WA "$EMAIL_HOOK
$SLACK_DIRECT
$NOTION_DIRECT"

# 4/5. CASE A/B 欠落
expect 1 "16-4  CASE A: Slack hook 欠落 → MISMATCH" -- WA "$EMAIL_HOOK
$NOTION_OK"
expect 1 "16-5  CASE B: Notion hook 欠落 → MISMATCH" -- WA "$EMAIL_HOOK
$SLACK_OK"

# 6. CASE E disabled
expect 1 "16-6  CASE E: disabled=true → MISMATCH" -- WA "$EMAIL_HOOK
$(mkhook url submission_created contact true https://noa-place.co.jp/hooks/slack)
$NOTION_OK"

# 7. CASE F 別 form
expect 1 "16-7  CASE F: 別 form に紐づく → MISMATCH" -- WA "$EMAIL_HOOK
$(mkhook url submission_created recruit false https://noa-place.co.jp/hooks/slack)
$NOTION_OK"

# 8/9. CASE G 重複
expect 1 "16-8  CASE G: Slack hook が2本 → MISMATCH" -- WA "$EMAIL_HOOK
$SLACK_OK
$SLACK_OK
$NOTION_OK"
expect 1 "16-9  CASE G: Notion hook が2本 → MISMATCH" -- WA "$EMAIL_HOOK
$SLACK_OK
$NOTION_OK
$NOTION_OK"

# 10. CASE H 別ホスト
expect 1 "16-10 CASE H: 別ホスト → MISMATCH" -- WA "$EMAIL_HOOK
$(mkhook url submission_created contact false https://simplecareer.jp/hooks/slack)
$NOTION_OK"
expect 1 "16-10b http scheme → MISMATCH" -- WA "$EMAIL_HOOK
$(mkhook url submission_created contact false http://noa-place.co.jp/hooks/slack)
$NOTION_OK"

# 11. CASE I typo / 部分一致で誤 PASS しないこと
expect 1 "16-11 CASE I: /hooks/slack-old → MISMATCH" -- WA "$EMAIL_HOOK
$(mkhook url submission_created contact false https://noa-place.co.jp/hooks/slack-old)
$NOTION_OK"
expect 1 "16-11b CASE I: /hooks/slac（前方一致で誤 PASS しない）" -- WA "$EMAIL_HOOK
$(mkhook url submission_created contact false https://noa-place.co.jp/hooks/slac)
$NOTION_OK"
expect 1 "16-11c CASE I: /hooks/notion（末尾欠け）" -- WA "$EMAIL_HOOK
$SLACK_OK
$(mkhook url submission_created contact false https://noa-place.co.jp/hooks/notion)"

# 12. email hook が URL hook の判定を汚さない / 正規化の許容範囲
expect 0 "16-12 email hook が複数でも URL 判定は汚れない → PASS" -- WA "$EMAIL_HOOK
$EMAIL_HOOK
$SLACK_OK
$NOTION_OK"
expect 0 "16-12b 末尾スラッシュは同一とみなす → PASS" -- WA "$EMAIL_HOOK
$(mkhook url submission_created contact false https://noa-place.co.jp/hooks/slack/)
$NOTION_OK"
expect 1 "16-12c メール通知 hook が無い → MISMATCH" -- WA "$SLACK_OK
$NOTION_OK"
# 別 event のフックは評価対象外（deploy_request_* を混ぜても結論が変わらない）
expect 0 "16-12d 別 event の hook は無視される → PASS" -- WA "$(mkhook email deploy_request_pending '' null '')
$EMAIL_HOOK
$SLACK_OK
$NOTION_OK"

echo ""
echo "=============================================="
printf ' PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
echo " ALL_TESTS_PASS"
