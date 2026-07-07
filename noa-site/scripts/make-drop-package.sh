#!/usr/bin/env bash
# =============================================================
# Netlify Drop 用 本番アップロードパッケージ生成スクリプト
#
# 使い方:
#   bash scripts/make-drop-package.sh <git-ref>
#   例) bash scripts/make-drop-package.sh redesign/v2
#   例) bash scripts/make-drop-package.sh baseline-v1-2026-07-07   # rollback用
#
# ルール:
# - パッケージは必ず「コミット済みの ref」から生成する（作業中ファイルからは作らない）
# - 生成物 noa-site/release/ は git 管理外（.gitignore 済み）
# - パッケージ内の deploy-info.json で「どのコミットが本番か」を後から検証できる
# =============================================================
set -euo pipefail

REF="${1:?git ref を指定してください (例: redesign/v2 / baseline-v1-2026-07-07)}"
ROOT="$(git rev-parse --show-toplevel)"
SHA="$(git rev-parse --short "$REF")"
FULL_SHA="$(git rev-parse "$REF")"
DATE="$(date +%Y-%m-%d)"
NAME="noa-drop_${DATE}_${REF//\//-}_${SHA}"
RELEASE="$ROOT/noa-site/release"
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

# netlify.toml は Drop では読まれないため、file-based config を同梱して
# SPA リダイレクトとセキュリティヘッダを確実に効かせる
printf '/*  /index.html  200\n' > "$OUT/_redirects"
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

( cd "$RELEASE" && rm -f "$NAME.zip" && zip -qr "$NAME.zip" "$NAME" )

echo "✅ package : noa-site/release/$NAME"
echo "✅ zip     : noa-site/release/$NAME.zip"
echo ""
echo "次の手順:"
echo "  比較用プレビュー → https://app.netlify.com/drop に folder をドロップ（新規サイトが生成される）"
echo "  本番反映         → 本番サイトの Deploys 画面に folder をドロップ（/drop ページは使わない！）"
echo "  反映後の検証     → curl https://noa-place.co.jp/deploy-info.json で commit が一致するか確認"
