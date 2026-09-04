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
