#!/usr/bin/env bash
# =============================================================
# 静的パッケージ生成スクリプト（既定は PREVIEW 専用）
#
# 使い方:
#   bash scripts/make-drop-package.sh <git-ref>
#   例) bash scripts/make-drop-package.sh redesign/v2
#   例) bash scripts/make-drop-package.sh baseline-v1-2026-07-07   # rollback用
#
# ⚠️ このスクリプトの生成物は「静的ファイルのみ」で Netlify Functions を含まない。
#    本番へ投入すると slack / notion-intake が消失し、問い合わせの
#    Slack 通知と Notion 登録が無検知で停止する（2026-08-30 に実際に発生）。
#    本番反映は必ず scripts/deploy-prod.sh を使うこと。
#
# ルール:
# - パッケージは必ず「コミット済みの ref」から生成する（作業中ファイルからは作らない）
# - 生成物 noa-site/release/ は git 管理外（.gitignore 済み）
# - パッケージ内の deploy-info.json で「どのコミットが本番か」を後から検証できる
#
# NOA_PACKAGE_MODE:
#   preview    (既定) … フォルダ名に PREVIEW_ONLY を付け、警告マーカーを同梱する
#   production        … deploy-prod.sh からのみ使用。マーカーを同梱しない
#                       （公開ディレクトリに警告ファイルを置かないため）
# =============================================================
set -euo pipefail

REF="${1:?git ref を指定してください (例: redesign/v2 / baseline-v1-2026-07-07)}"
MODE="${NOA_PACKAGE_MODE:-preview}"
ROOT="$(git rev-parse --show-toplevel)"
SHA="$(git rev-parse --short "$REF")"
FULL_SHA="$(git rev-parse "$REF")"
DATE="$(date +%Y-%m-%d)"
RELEASE="$ROOT/noa-site/release"

if [ "$MODE" = "production" ]; then
  NAME="noa-drop_${DATE}_${REF//\//-}_${SHA}"
else
  NAME="PREVIEW_ONLY_noa-drop_${DATE}_${REF//\//-}_${SHA}"
fi
OUT="$RELEASE/$NAME"
WT="$RELEASE/.wt-$SHA"

cd "$ROOT"
mkdir -p "$RELEASE"
rm -rf "$OUT" "$WT" 2>/dev/null || true

# ref の内容を一時 worktree に展開（作業ツリー・index を汚さない）
git worktree add --detach "$WT" "$REF" >/dev/null
mkdir -p "$OUT"
cp -R "$WT/noa-site/public/." "$OUT/"
git worktree remove --force "$WT"

# netlify.toml は手動デプロイでは読まれないため、file-based config を同梱して
# SPA リダイレクトとセキュリティヘッダを確実に効かせる
# _redirects は netlify.toml より先に処理され、上から first-match。
# 未配備 function を SPA catch-all に吸わせないルールを catch-all の前に置く
# （force を付けないので、実在する function はこのルールをシャドウする）。
cat > "$OUT/_redirects" <<'EOF'
/.netlify/functions/*  /function-not-found.txt  404
/*                     /index.html              200
EOF
cat > "$OUT/_headers" <<'EOF'
/*
  X-Frame-Options: DENY
  X-XSS-Protection: 1; mode=block
  X-Content-Type-Options: nosniff
EOF

# 本番検証用マーカー（公開されるが ref/sha/日付のみ。秘密情報は含めない）
cat > "$OUT/deploy-info.json" <<EOF
{ "ref": "$REF", "commit": "$FULL_SHA", "packaged_at": "$DATE" }
EOF

# deploy-prod.sh が生成先を推測しなくて済むよう、パスを受け渡す
printf '%s\n' "$OUT" > "$RELEASE/.last-package-path"

if [ "$MODE" = "production" ]; then
  echo "✅ production package : noa-site/release/$NAME"
  exit 0
fi

# ---- PREVIEW モード: 誤って本番へ投入されないよう二重に警告 ----
cat > "$OUT/PREVIEW_ONLY_DO_NOT_DEPLOY_TO_PRODUCTION.txt" <<'EOF'
==================================================
PREVIEW ONLY
DO NOT DEPLOY THIS PACKAGE TO noa-place.co.jp
Production must use scripts/deploy-prod.sh
==================================================

このフォルダには Netlify Functions が含まれていません。

本番サイトへ投入すると以下が消失します:
  - netlify/functions/slack         （問い合わせの Slack 通知）
  - netlify/functions/notion-intake （問い合わせの Notion 登録）

しかも SPA catch-all により未配備の function へは 200 + index.html が
返るため、通知の停止がどこにも表面化しません。
（2026-08-30 に実際に発生。8/30〜9/4 の問い合わせ通知が停止しました）

正しい本番反映:
  bash scripts/deploy-prod.sh <git-ref>

比較プレビュー（推奨・Functions 込み）:
  bash scripts/deploy-preview.sh <git-ref>
EOF

( cd "$RELEASE" && rm -f "$NAME.zip" && zip -qr "$NAME.zip" "$NAME" )

echo ""
echo "=================================================="
echo " PREVIEW ONLY"
echo " DO NOT DEPLOY THIS PACKAGE TO noa-place.co.jp"
echo " Production must use scripts/deploy-prod.sh"
echo "=================================================="
echo ""
echo "✅ package : noa-site/release/$NAME"
echo "✅ zip     : noa-site/release/$NAME.zip"
echo ""
echo "このパッケージには Netlify Functions が含まれていません。"
echo "本番へ投入すると Slack 通知 / Notion 登録が無検知で停止します。"
echo ""
echo "次の手順:"
echo "  比較プレビュー（推奨） → bash scripts/deploy-preview.sh $REF"
echo "      Functions 込みの draft deploy を作り、一意の Preview URL を発行します。"
echo "  本番反映               → bash scripts/deploy-prod.sh $REF"
echo "      ブラウザからのフォルダドロップは本番では使用禁止です。"
