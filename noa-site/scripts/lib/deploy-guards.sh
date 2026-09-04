#!/usr/bin/env bash
# =============================================================
# デプロイ Guard 共通ライブラリ
#
# 設計方針:
#   判定ロジック（assert_*）は「引数で受け取った値だけ」で結論を出す純関数にし、
#   ネットワーク I/O は fetch_* / probe_* に隔離する。
#   こうすることで scripts/test/deploy-guard-tests.sh が
#   curl も Netlify API も叩かずに全分岐を再現できる。
#
# 由来: 2026-08-30 のインシデント（本番へ static-only アーティファクトが投入され
#       slack / notion-intake が消失。Slack通知とNotion登録が無検知で停止）
# =============================================================

guard_pass() { printf '  [PASS] %s\n' "$*"; }
guard_fail() { printf '  [FAIL] %s\n' "$*" >&2; }

# -------------------------------------------------------------
# R1: 必須 function のソースが存在するか（デプロイ前）
#   assert_required_function_files <functions_dir> <fn...>
# -------------------------------------------------------------
assert_required_function_files() {
  local dir="$1"; shift
  local rc=0 fn
  for fn in "$@"; do
    if [ -f "$dir/$fn.js" ]; then
      guard_pass "function source: $fn.js"
    else
      guard_fail "MISSING_REQUIRED_FUNCTION: $fn.js が $dir に存在しません"
      rc=1
    fi
  done
  return $rc
}

# -------------------------------------------------------------
# R2: link 先が本番サイトか（デプロイ前）
#   assert_site_identity <actual_site_id> <actual_domain> <expected_site_id> <expected_domain>
#   actual_site_id / actual_domain が空 = 未link・取得失敗として FAIL 扱い
# -------------------------------------------------------------
assert_site_identity() {
  local a_id="$1" a_dom="$2" e_id="$3" e_dom="$4"
  local rc=0
  if [ -z "$a_id" ]; then
    guard_fail "SITE_IDENTITY_MISMATCH: Netlify サイトが未linkです（.netlify/state.json なし / netlify link 未実行）"
    return 1
  fi
  if [ "$a_dom" = "$e_dom" ]; then
    guard_pass "custom_domain: $a_dom"
  else
    guard_fail "SITE_IDENTITY_MISMATCH: custom_domain expected '$e_dom', got '${a_dom:-(none)}'"
    rc=1
  fi
  if [ "$a_id" = "$e_id" ]; then
    guard_pass "site_id: 本番サイトと一致"
  else
    guard_fail "SITE_IDENTITY_MISMATCH: site_id が本番と異なります（別サイトへのデプロイを阻止しました）"
    rc=1
  fi
  return $rc
}

# -------------------------------------------------------------
# R3: 実際の本番 deploy metadata に function が載っているか（デプロイ後）
#   assert_deployed_functions <actual_space_separated> <required...>
#   「ローカルにファイルがある」ではなく Netlify 側の available_functions を見る
# -------------------------------------------------------------
assert_deployed_functions() {
  local actual="$1"; shift
  local rc=0 fn
  if [ -z "$actual" ]; then
    guard_fail "MISSING_DEPLOYED_FUNCTION: deploy metadata に function が1つも含まれていません（static-only デプロイの疑い）"
    return 1
  fi
  for fn in "$@"; do
    case " $actual " in
      *" $fn "*) guard_pass "deploy metadata: $fn" ;;
      *) guard_fail "MISSING_DEPLOYED_FUNCTION: $fn が本番 deploy metadata にありません（available=[$actual]）"; rc=1 ;;
    esac
  done
  return $rc
}

# -------------------------------------------------------------
# R4: 本番ランタイムが function 由来の応答を返すか（デプロイ後）
#   assert_runtime_endpoint <name> <http_status> <content_type>
#   期待: 405（POST以外を拒否するガード応答） かつ text/html でないこと
#   2026-08-30 の事故状態（200 + text/html + index.html）を確実に FAIL させる
# -------------------------------------------------------------
assert_runtime_endpoint() {
  local name="$1" http_status="$2" ctype="$3"
  case "$ctype" in
    *text/html*)
      guard_fail "$name: expected 405, got ${http_status} ${ctype%%;*} — SPA fallback の index.html が返っています（function 未配備）"
      return 1 ;;
  esac
  if [ "$http_status" = "405" ]; then
    guard_pass "$name: 405 (${ctype%%;*})"
    return 0
  fi
  guard_fail "$name: expected 405, got ${http_status} ${ctype%%;*}"
  return 1
}

# -------------------------------------------------------------
# A1: alias ルートの定義順が正しいか（純関数・引数は _redirects 相当の文字列）
#   assert_alias_rule_order <redirects_text>
#   要件: 実在 function への明示 rewrite が /hooks/* フォールバックより前、
#         かつ /hooks/* フォールバックが SPA catch-all より前にあること。
#   （rules は上から first-match なので順序が逆だと alias が死ぬ）
# -------------------------------------------------------------
assert_alias_rule_order() {
  local text="$1"
  local rc=0 line n=0 i_slack=0 i_notion=0 i_fallback=0 i_catchall=0
  while IFS= read -r line; do
    case "$line" in ""|"#"*) continue ;; esac
    n=$((n+1))
    case "$line" in
      "/hooks/slack "*)         [ "$i_slack" -eq 0 ] && i_slack=$n ;;
      "/hooks/notion-intake "*) [ "$i_notion" -eq 0 ] && i_notion=$n ;;
      "/hooks/* "*)             [ "$i_fallback" -eq 0 ] && i_fallback=$n ;;
      "/* "*)                   [ "$i_catchall" -eq 0 ] && i_catchall=$n ;;
    esac
  done <<< "$text"

  if [ "$i_slack" -gt 0 ]; then guard_pass "alias 定義: /hooks/slack"
  else guard_fail "MISSING_ALIAS_ROUTE: /hooks/slack が未定義"; rc=1; fi

  if [ "$i_notion" -gt 0 ]; then guard_pass "alias 定義: /hooks/notion-intake"
  else guard_fail "MISSING_ALIAS_ROUTE: /hooks/notion-intake が未定義"; rc=1; fi

  if [ "$i_fallback" -gt 0 ]; then
    if [ "$i_slack" -gt 0 ] && [ "$i_slack" -gt "$i_fallback" ]; then
      guard_fail "ALIAS_RULE_ORDER: /hooks/* フォールバックが /hooks/slack より前にあります"; rc=1
    elif [ "$i_notion" -gt 0 ] && [ "$i_notion" -gt "$i_fallback" ]; then
      guard_fail "ALIAS_RULE_ORDER: /hooks/* フォールバックが /hooks/notion-intake より前にあります"; rc=1
    else
      guard_pass "alias 順序: 明示 rewrite → /hooks/* フォールバック"
    fi
  else
    guard_fail "MISSING_ALIAS_ROUTE: /hooks/* の 404 フォールバックが未定義"; rc=1
  fi

  if [ "$i_catchall" -gt 0 ] && [ "$i_fallback" -gt 0 ] && [ "$i_catchall" -lt "$i_fallback" ]; then
    guard_fail "ALIAS_RULE_ORDER: SPA catch-all が /hooks/* より前にあります"; rc=1
  elif [ "$i_catchall" -gt 0 ]; then
    guard_pass "alias 順序: /hooks/* → SPA catch-all"
  fi
  return $rc
}

# -------------------------------------------------------------
# W1-W3: Netlify Forms の Outgoing Webhook 設定監査（純関数）
#
#   assert_webhook_configuration <hooks_tsv> <form> <slack_url> <notion_url>
#
# hooks_tsv は1行1フックの TSV:
#   <type>\t<event>\t<form_name>\t<disabled>\t<url>
# （I/O は fetch_hooks_tsv が担当。ここはネットワークに触れない）
#
# 評価対象は event = submission_created のフックのみ。
# URL は正規化してから完全一致で比較する（部分一致では PASS させない）。
# -------------------------------------------------------------

# query string / fragment を落とし、末尾スラッシュを1つ除去する
normalize_hook_url() {
  local u="${1%%\#*}"
  u="${u%%\?*}"
  case "$u" in */) u="${u%/}" ;; esac
  printf '%s' "$u"
}

assert_webhook_configuration() {
  local tsv="$1" want_form="$2" want_slack="$3" want_notion="$4"
  local rc=0
  local n_slack=0 n_notion=0 n_email=0 n_other=0
  local bad_form=0 bad_disabled=0
  local other_urls="" line type event form disabled url nurl

  want_slack="$(normalize_hook_url "$want_slack")"
  want_notion="$(normalize_hook_url "$want_notion")"

  while IFS="$(printf '\t')" read -r type event form disabled url; do
    [ -n "${type:-}" ] || continue
    [ "$event" = "submission_created" ] || continue

    if [ "$type" = "email" ]; then
      n_email=$((n_email+1))
      continue
    fi
    [ "$type" = "url" ] || continue

    nurl="$(normalize_hook_url "$url")"
    case "$nurl" in
      "$want_slack")  n_slack=$((n_slack+1)) ;;
      "$want_notion") n_notion=$((n_notion+1)) ;;
      *)              n_other=$((n_other+1)); other_urls="$other_urls $nurl" ;;
    esac

    # 期待URLに一致したフックだけ、form と disabled を追加検証する
    if [ "$nurl" = "$want_slack" ] || [ "$nurl" = "$want_notion" ]; then
      [ "$form" = "$want_form" ] || { bad_form=$((bad_form+1)); \
        guard_fail "WEBHOOK_CONFIGURATION_MISMATCH: $nurl が form='$form' に紐づいています（期待: '$want_form'）"; }
      [ "$disabled" = "false" ] || { bad_disabled=$((bad_disabled+1)); \
        guard_fail "WEBHOOK_CONFIGURATION_MISMATCH: $nurl が disabled=$disabled です"; }
    fi
  done <<EOF
$tsv
EOF

  # --- CASE A / G: Slack hook ---
  case "$n_slack" in
    1) guard_pass "Slack hook: $want_slack" ;;
    0) guard_fail "WEBHOOK_CONFIGURATION_MISMATCH: Slack hook が見つかりません（期待: $want_slack）"; rc=1 ;;
    *) guard_fail "WEBHOOK_CONFIGURATION_MISMATCH: Slack hook が $n_slack 本あります（重複通知の恐れ）"; rc=1 ;;
  esac

  # --- CASE B / G: Notion hook ---
  case "$n_notion" in
    1) guard_pass "Notion hook: $want_notion" ;;
    0) guard_fail "WEBHOOK_CONFIGURATION_MISMATCH: Notion hook が見つかりません（期待: $want_notion）"; rc=1 ;;
    *) guard_fail "WEBHOOK_CONFIGURATION_MISMATCH: Notion hook が $n_notion 本あります（重複通知の恐れ）"; rc=1 ;;
  esac

  # --- CASE C / D / H / I: 期待外の URL hook（旧 direct path・別ホスト・typo）---
  if [ "$n_other" -eq 0 ]; then
    guard_pass "想定外の URL hook: なし"
  else
    for u in $other_urls; do
      case "$u" in
        *"/.netlify/functions/"*)
          guard_fail "WEBHOOK_CONFIGURATION_MISMATCH: 旧 direct path が設定されています → $u（未配備時に 200+index.html を返し障害が無検知になる）" ;;
        *) guard_fail "WEBHOOK_CONFIGURATION_MISMATCH: 想定外の URL hook → $u" ;;
      esac
    done
    rc=1
  fi

  # --- CASE E / F ---
  [ "$bad_form" -eq 0 ] || rc=1
  [ "$bad_disabled" -eq 0 ] || rc=1
  if [ "$bad_form" -eq 0 ] && [ "$bad_disabled" -eq 0 ] && [ "$n_slack" -eq 1 ] && [ "$n_notion" -eq 1 ]; then
    guard_pass "event=submission_created / form=$want_form / disabled=false"
  fi

  # --- email 通知（宛先内容は検証しない。存在のみ）---
  case "$n_email" in
    0) guard_fail "WEBHOOK_CONFIGURATION_MISMATCH: メール通知の hook がありません"; rc=1 ;;
    *) guard_pass "メール通知 hook: $n_email 件（宛先内容は検証対象外）" ;;
  esac

  return $rc
}

# =============================================================
# 以下は I/O 担当（テストからは呼ばない）
# =============================================================

# linked site id を取得（未link なら空文字）
fetch_linked_site_id() {
  local state="$1/.netlify/state.json"
  [ -f "$state" ] || return 0
  node -e 'try{const s=require(process.argv[1]);process.stdout.write(s.siteId||"")}catch(e){}' "$state" 2>/dev/null || true
}

# getSite を1回だけ叩き "<site_id>\t<custom_domain>\t<available_functions(space)>" を返す
fetch_site_facts() {
  local site_id="$1"
  npx --yes netlify-cli api getSite --data "{\"site_id\":\"$site_id\"}" 2>/dev/null \
    | node -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        try{
          const o=JSON.parse(s), pd=o.published_deploy||{};
          const fns=(pd.available_functions||[]).map(f=>f.n||f.name).sort();
          process.stdout.write([o.id||"",o.custom_domain||"",fns.join(" ")].join("\t"));
        }catch(e){process.stdout.write("\t\t")}
      })' 2>/dev/null || printf '\t\t'
}

# 指定 deploy の available_functions を取得（deploy-prod.sh が自分のdeployを検証する用）
fetch_deploy_functions() {
  local deploy_id="$1"
  npx --yes netlify-cli api getDeploy --data "{\"deploy_id\":\"$deploy_id\"}" 2>/dev/null \
    | node -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        try{
          const d=JSON.parse(s);
          process.stdout.write((d.available_functions||[]).map(f=>f.n||f.name).sort().join(" "));
        }catch(e){}
      })' 2>/dev/null || true
}

# GET のみ。本番データを一切生成しない安全なプローブ。"<status>\t<content_type>"
probe_endpoint() {
  curl -s -o /dev/null --max-time 20 -w '%{http_code}\t%{content_type}' "$1" 2>/dev/null || printf '000\t'
}

# Netlify の hook 設定を TSV で取得（url の query/fragment は落として渡すため、
# トークン等が付いていても出力・比較に混入しない）
fetch_hooks_tsv() {
  local site_id="$1"
  npx --yes netlify-cli api listHooksBySiteId --data "{\"site_id\":\"$site_id\"}" 2>/dev/null \
    | node -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        try{
          JSON.parse(s).forEach(h=>{
            const raw=(h.data&&h.data.url)||"";
            const url=raw.split("#")[0].split("?")[0];
            process.stdout.write([h.type||"",h.event||"",h.form_name||"",String(h.disabled),url].join("\t")+"\n");
          });
        }catch(e){}
      })' 2>/dev/null || true
}
