# 本番運用ルール（Netlify Drop × GitHub 併用）

作成日: 2026-07-07
前提: 本番 noa-place.co.jp は **Netlify Drop（手動アップロード）** で反映。
GitHub（lumenarbor/noa.Inc-official）は **履歴管理・rollback 管理の source of truth**。

---

## 大原則（これだけは守る）

1. **本番に上げてよいのは、このスクリプトで作ったパッケージだけ**
   `bash noa-site/scripts/make-drop-package.sh <ref>`
   作業中フォルダや手元で編集したファイルを直接ドロップしない。
   パッケージは必ず「コミット済み・push 済みの ref」から作る。
2. **アップロード先を間違えない**
   - 比較・プレビュー → https://app.netlify.com/drop （**新規サイト**が作られる。本番は無傷）
   - 本番反映 → Netlify 管理画面で **本番サイトを開き、Deploys タブ**にドロップ
   - `/drop` ページに本番のつもりでドロップしても本番は更新されない（逆の事故も防げる）
3. **反映後は必ず検証マーカーを確認**
   `curl https://noa-place.co.jp/deploy-info.json`
   → 表示される `commit` が、上げたつもりのコミットと一致すること。
   これで「どのコミットが本番か」が常に機械的に証明できる。

---

## 手順A: 新案の比較・確認（本番を触らない）

```bash
cd ~/Desktop/noa.Inc-official
bash noa-site/scripts/make-drop-package.sh redesign/v2
```
1. 生成された `noa-site/release/noa-drop_..._redesign-v2_...` フォルダを
   https://app.netlify.com/drop へドロップ → プレビューURLが発行される
2. 本番（noa-place.co.jp）と並べて比較。関係者にURL共有
3. プレビューURL上で `?flags=loader:v1,transitions:v1,stickyCta:off,ctaLanes:off,formPlus:off`
   を付ければ**同じデプロイ内で新旧を切替比較**できる（機能単位のON/OFFも可）
4. プレビュー用サイトは使い終わったら Netlify 上で削除してよい（残しても無害）

## 手順B: 本番反映

1. 反映するコミットが GitHub に push 済みであることを確認
2. `bash noa-site/scripts/make-drop-package.sh <ref>` でパッケージ生成
3. Netlify 管理画面 → 本番サイト → **Deploys** タブ → パッケージフォルダをドロップ
4. `curl https://noa-place.co.jp/deploy-info.json` で commit 一致を確認
5. スモークチェック（下記チェックリスト）
6. Git に記録:
   ```bash
   git tag deploy/$(date +%Y-%m-%d)-1 <ref>   # 同日2回目は -2
   git push origin --tags
   ```
   `docs/DEPLOY-LOG.md` に1行追記して commit & push

### 本番反映後チェックリスト
- [ ] deploy-info.json の commit 一致
- [ ] トップ表示・ローダー挙動
- [ ] ページ遷移（Philosophy / Services / Contact）
- [ ] **問い合わせフォームのテスト送信1件**（Netlify Forms が受信しているか Forms タブで確認）
- [ ] モバイル実機で固定CTAの出現・退場
- [ ] /admin（CMS）が開くか

## 手順C: Rollback（3層。上から順に使う）

| 層 | 方法 | 所要 | 用途 |
|---|---|---|---|
| 1 | **Netlify デプロイ履歴**: Deploys タブ → 直前のデプロイを開く → **Publish deploy** | 数秒 | 直近のアップロードを取り消したい |
| 2 | **フラグ rollback**: `SITE_FLAGS` の該当項目を `'v1'/'off'` に変更 → commit → パッケージ再生成 → Drop | 数分 | 特定機能だけ現行に戻したい（セクション単位） |
| 3 | **baseline 再アップロード**: `bash noa-site/scripts/make-drop-package.sh baseline-v1-2026-07-07` → Drop | 数分 | 完全に現行版へ戻したい |

- 層1が最速。Netlify は過去の Drop デプロイをすべて保持しており、ワンクリックで公開デプロイを切り替えられる。
- 層3の baseline パッケージは**事前生成済み**: `noa-site/release/noa-drop_2026-07-07_baseline-v1-2026-07-07_e75e7ee/`
  （いつでも再生成可能。タグ `baseline-v1-2026-07-07` が恒久的な復元点）

---

## コミット ↔ 本番の対応ルール

- 本番に上げた ref には必ず `deploy/YYYY-MM-DD-n` タグを打つ（GitHub 上で本番履歴が一覧できる）
- `docs/DEPLOY-LOG.md` が台帳。「いつ / どのコミット / 何を変えた / 誰が確認したか」を1行で残す
- 本番の実体確認はいつでも `curl https://noa-place.co.jp/deploy-info.json`
- ブランチ運用: 開発は `redesign/v2`（以降は機能ごとに `redesign/v2-<機能名>` でも可）。
  本番採用が確定したら `main` へマージし、以後 `main` = 本番相当を維持する

## 本番を壊さないための注意点

- **netlify.toml は Drop では読まれない** → パッケージに `_redirects` / `_headers` を自動同梱済み（スクリプトが生成）。SPA リダイレクトとセキュリティヘッダはこれで担保される
- **Netlify Functions（netlify/functions/slack.js）は Drop ではデプロイされない** → 現行本番も Drop 運用のため同条件（機能後退なし）だが、フォームの Slack 通知が必要なら Netlify Forms の Email/Slack 通知設定（管理画面）で代替すること
- Netlify 管理画面上でのファイル直編集・別フォルダの直接ドロップは禁止
- パッケージ生成元の ref が GitHub に push 済みであることを常に確認（ローカルにしかないコミットを本番化しない）
- `release/` は git 管理外。台帳とタグが対応関係の記録

---

## （将来）Git 連携へ移行する場合の安全手順

急がない。移行する時は以下の順で行えば無停止・無リスク:

1. Netlify で**新規サイト**を作り、GitHub リポジトリの `main` に接続
   （Base directory: `noa-site` / Publish directory: `noa-site/public` / Build command: なし）
2. 新サイトの netlify.app URL で本番同等に動くことを確認（Forms の再有効化・通知設定もここで）
3. Branch deploys を有効化 → `redesign/*` ブランチが自動でプレビューURL化（手順Aが自動化される）
4. 問題なければ **カスタムドメイン noa-place.co.jp を新サイトへ付け替え**（DNS/ドメイン設定の移動のみ。旧サイトはそのまま残す = 即時退避先）
5. 数週間併走して安定を確認後、旧サイトを整理

移行の合図: Drop 運用で「アップロード頻度が週1を超える」「複数人で反映する」ようになったら移行推奨。
