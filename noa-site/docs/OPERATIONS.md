# 本番運用ルール（Netlify CLI × GitHub 併用）

作成日: 2026-07-07 / 最終更新: 2026-09-04（2026-08-30 インシデントを受けた Deployment Guard 導入）
前提: 本番 noa-place.co.jp は **Netlify CLI による手動デプロイ**（continuous deployment 未設定）。
GitHub（lumenarbor/noa.Inc-official）は **履歴管理・rollback 管理の source of truth**。

---

## 経路は2つだけ

| 用途 | コマンド | 本番への影響 |
|---|---|---|
| **比較プレビュー** | `bash scripts/deploy-preview.sh <ref> [alias]` | なし（draft deploy） |
| **本番反映** | `bash scripts/deploy-prod.sh <ref>` | あり（Guard 通過時のみ） |
| 現在の本番の健全性確認 | `bash scripts/verify-prod-deploy.sh` | なし（GET のみ） |

### ⛔ Netlify Drop / ブラウザへのフォルダドロップは本番では使用禁止

ブラウザから本番サイトの Deploys 画面へフォルダをドロップすると、
**静的ファイルだけが配備され Netlify Functions が本番から消失する**。
その結果:

- `netlify/functions/slack` → 問い合わせの Slack 通知が停止
- `netlify/functions/notion-intake` → 問い合わせの Notion 登録が停止
- Netlify Forms のメール通知だけは Function 非依存なので**生き残る**

さらに SPA catch-all（`/* → /index.html 200`）により、未配備の function URL へは
**404 ではなく 200 + index.html** が返る。Netlify の Outgoing Webhook からは「成功」に
見えるため、**通知の停止がどこにも表面化しない**。

実際に2度発生している:

| 日付 | 影響 |
|---|---|
| 2026-07-08 | Slack 通知が停止（当時 notion-intake は未実装） |
| 2026-08-30 | Slack 通知 + Notion 登録が同時停止。9/4 まで無検知。問い合わせ1件が取りこぼし（後日 Backfill 済み） |

---

## Deployment Guard（2026-09-04 導入）

`scripts/deploy-prod.sh` は Guard を通過しない限り本番へ到達しない。

| Gate | 内容 | 失敗時のメッセージ |
|---|---|---|
| R1 デプロイ前 | `netlify/functions/{slack,notion-intake}.js` が存在するか | `PRODUCTION_DEPLOY_BLOCKED` / `MISSING_REQUIRED_FUNCTION` |
| R2 デプロイ前 | link 先が本番サイト（custom_domain・site_id 一致）か | `PRODUCTION_DEPLOY_BLOCKED` / `SITE_IDENTITY_MISMATCH` |
| R3 デプロイ後 | Netlify の deploy metadata に両 function が載っているか | `PRODUCTION_DEPLOY_VERIFICATION_FAILED` / `MISSING_DEPLOYED_FUNCTION` |
| R4 デプロイ後 | Webhook が叩く `/hooks/*` が **405** を返すか（`text/html` は即 FAIL） | `PRODUCTION_DEPLOY_VERIFICATION_FAILED` |
| R4b デプロイ後 | 未定義の `/hooks/*` が **4xx** か（200 なら SPA catch-all に吸われている） | `ALIAS_FALLBACK_BROKEN` |
| R4c デプロイ後 | `/.netlify/functions/*` も 405 か（内部健全性） | `PRODUCTION_DEPLOY_VERIFICATION_FAILED` |
| R5 デプロイ後 | **Netlify Forms の Outgoing Webhook が alias URL を向いているか**（Netlify UI 側の設定監査） | `WEBHOOK_CONFIGURATION_MISMATCH` |

- R3 は「ローカルにファイルがある」では PASS しない。**Netlify 側の `available_functions` を見る。**
- R4 は 2026-08-30 の事故状態（`200 + text/html + index.html`）を確実に FAIL させる。
- 本番サイトの同一性は `scripts/prod-site.conf` が single source of truth（秘密情報は含まない）。
- Guard の回帰テスト: `bash scripts/test/deploy-guard-tests.sh`（ネットワーク不要・本番に触れない）

---

## 通知アーキテクチャ（2026-09-04 alias 移行後）

```
Netlify Forms (form = contact)
  ├─ email hook ─────────────────────────────► メール通知（Function 非依存）
  ├─ url hook → /hooks/slack ────────────────► /.netlify/functions/slack
  └─ url hook → /hooks/notion-intake ────────► /.netlify/functions/notion-intake
```

**Outgoing Webhook には `/.netlify/functions/*` を直接指定しない。**

理由（2026-09-04 に draft deploy で実測確定）:

- `/.netlify/` は Netlify の予約名前空間で、redirect の `from` に指定できない。
  CLI が `"path" field must not start with "/.netlify"` で明示的に拒否する。
  `force`（`404!`）でも不可。
- にもかかわらず Netlify 自身の SPA catch-all は同パスに適用される。
  その結果、function が未配備だと **200 + index.html** が返り、
  Outgoing Webhook 側は「成功」と誤認する。
  これが 2026-08-30 の障害が5日間無検知だった直接の原因。
- 予約外 prefix（`/hooks/*`）から rewrite すれば、未配備 function は **404** になる。
  POST もメソッド・ボディともに rewrite を透過する
  （直接叩いた場合とバイト単位で同一のレスポンスを実測確認済み）。

| Path | 用途 | function 配備時 | function 未配備時 |
|---|---|---:|---:|
| `/hooks/slack` | **Outgoing Webhook 用** | 405 (GET) | **404** |
| `/hooks/notion-intake` | **Outgoing Webhook 用** | 405 (GET) | **404** |
| `/hooks/<未定義>` | — | 404 | 404 |
| `/.netlify/functions/*` | 内部エンドポイント（監視・デバッグ用） | 405 (GET) | ⚠️ 200 + index.html |

### 正規の Outgoing Webhook（この2本以外を設定しない）

| 用途 | URL |
|---|---|
| Slack | `https://noa-place.co.jp/hooks/slack` |
| Notion | `https://noa-place.co.jp/hooks/notion-intake` |

**禁止: Outgoing Webhook に `/.netlify/functions/*` を直接設定しない。**
未配備時に 200 + index.html が返り、Netlify 側が「成功」と誤認するため。

この設定は `bash scripts/verify-prod-deploy.sh` の
**`[6/6] WEBHOOK_CONFIGURATION` Gate が Netlify UI の実設定まで監査する**。
期待値は `scripts/prod-site.conf` の `EXPECTED_SLACK_WEBHOOK_URL` /
`EXPECTED_NOTION_WEBHOOK_URL` / `EXPECTED_FORM_NAME` が正本。
誰かが UI から旧 direct path へ戻したり、hook を無効化・重複させたり、
別 form に付け替えたりすると `WEBHOOK_CONFIGURATION_MISMATCH` で落ちる。

検査は **read-only** で、Webhook 設定を書き換えることはない。
URL は query string / fragment を除去し、末尾スラッシュ1つを許容したうえで
scheme・hostname・path を完全一致で比較する（前方一致では PASS しない）。

`/.netlify/functions/*` は監視・デバッグ用の内部エンドポイントとして残してあるが、
**Webhook 設定には使わないこと**。
ルート定義は `netlify.toml` と `scripts/make-drop-package.sh`（`_redirects` 生成）の
両方にあり、順序が意味を持つ（上から first-match）。順序は
`scripts/test/deploy-guard-tests.sh` の CASE 10-12 が検証している。

---

## Preview の限界（重要）

`scripts/deploy-preview.sh` の draft deploy は **context = branch-deploy** で動く。
本番の環境変数（`NOTION_TOKEN` 等）はこの context の function ランタイムへ届かない。

| preview で確認できる | preview で確認できない |
|---|---|
| routing（`/hooks/*` の rewrite、404 フォールバック、SPA fallback） | Notion への書き込み |
| static content | Slack への投稿 |
| function が deploy に含まれているか（GET で 405 が返るか） | business logic の E2E |

**preview へ POST しないこと。** `notion-intake` が env missing 分岐に入り、
Slack へ「⚠️ 設定エラー」の警告が飛ぶ（2026-09-04 に実際に発生させた）。
E2E は本番フォームで行う。**本番の秘密情報を branch-deploy へコピーして
解決してはならない。**

---

## 大原則

1. **本番に上げてよいのは `scripts/deploy-prod.sh` 経由だけ**
   パッケージは必ず「コミット済み・push 済みの ref」から作られる（スクリプトが強制）。
   作業中フォルダを直接デプロイすることはできない。
2. **プレビューは `scripts/deploy-preview.sh`**
   `--prod` を付けない draft deploy。本番の公開デプロイを置き換えない。
   Functions も同梱するので「プレビューでは動いたのに本番で動かない」が起きない。
3. **反映後は Guard が自動で検証する**
   `deploy-prod.sh` はデプロイ直後に `verify-prod-deploy.sh` を実行し、
   落ちれば non-zero exit する。手で curl する運用には戻さない。
   検証範囲は Functions の配備・alias routing・ランタイム応答に加え、
   **Netlify UI 側の Outgoing Webhook 設定**まで含む（6 Gate）。

---

## 手順A: 新案の比較・確認（本番を触らない）

```bash
cd ~/Desktop/noa.Inc-official/noa-site
bash scripts/deploy-preview.sh redesign/v2
# 任意の別名を付けたい場合
bash scripts/deploy-preview.sh redesign/v2 hero-v3
```
1. 出力される **Draft URL** が比較用の Preview URL（`https://<alias>--bucolic-custard-646801.netlify.app`）
2. 本番（noa-place.co.jp）と並べて比較。関係者にURL共有
3. Preview URL に `?flags=loader:v1,transitions:v1,stickyCta:off,ctaLanes:off,formPlus:off`
   を付ければ**同じデプロイ内で新旧を切替比較**できる（機能単位のON/OFFも可）
4. draft deploy は本番の公開デプロイを置き換えない。放置しても無害

> `scripts/make-drop-package.sh` を単体で実行すると `PREVIEW_ONLY_...` という名前の
> 静的パッケージが生成され、中に `PREVIEW_ONLY_DO_NOT_DEPLOY_TO_PRODUCTION.txt` が入る。
> これは Functions を含まないため、**本番へ投入してはいけない**。
> 通常は `deploy-preview.sh` を使えばよく、単体実行が必要な場面はほぼない。

## 手順B: 本番反映（Netlify CLI・functions込み・Guard 付き）

初回のみ（要ブラウザ認証）:
```bash
cd ~/Desktop/noa.Inc-official/noa-site
npx --yes netlify-cli login     # ブラウザで認証
npx netlify-cli link            # 本番サイト(noa-place.co.jp)を選択
```

毎回:
1. 反映するコミットが GitHub に push 済みであることを確認
2. `bash scripts/deploy-prod.sh <ref>`
   - PREFLIGHT（R1/R2）→ パッケージ生成 → `deploy --prod --functions --no-build`
     → POST DEPLOY 検証（R3/R4）まで一気通貫。どこかで落ちれば non-zero exit
   - 検証 PASS 後、警告ラベルの無い本番用パッケージは `release/` から自動削除される
     （後からブラウザへドラッグできる無印フォルダを残さないため）
3. Guard が見ない残りを手で確認:
   - `curl -s https://noa-place.co.jp/deploy-info.json` → commit 一致
   - 本番フォームからテスト送信1件 → **Slack 受信 + Notion 登録**を確認
4. Git に記録:
   ```bash
   git tag deploy/$(date +%Y-%m-%d)-1 <ref>   # 同日2回目は -2
   git push origin --tags
   ```
   `docs/DEPLOY-LOG.md` に1行追記して commit & push

### 本番反映後チェックリスト
- [ ] `bash scripts/verify-prod-deploy.sh` → `ALL_GATES_PASS`
- [ ] deploy-info.json の commit 一致
- [ ] トップ表示・ローダー挙動
- [ ] ページ遷移（Philosophy / Services / Contact）
- [ ] **問い合わせフォームのテスト送信1件**（Netlify Forms / Slack / Notion の3経路すべて）
- [ ] モバイル実機で固定CTAの出現・退場
- [ ] /admin（CMS）が開くか

## 手順C: Rollback（3層。上から順に使う）

| 層 | 方法 | 所要 | 用途 |
|---|---|---|---|
| 1 | **Netlify デプロイ履歴**: Deploys タブ → 直前のデプロイを開く → **Publish deploy** | 数秒 | 直近のアップロードを取り消したい |
| 2 | **フラグ rollback**: `SITE_FLAGS` の該当項目を `'v1'/'off'` に変更 → commit → `bash scripts/deploy-prod.sh <ref>` | 数分 | 特定機能だけ現行に戻したい（セクション単位） |
| 3 | **baseline 再デプロイ**: `bash scripts/deploy-prod.sh baseline-v1-2026-07-07` | 数分 | 完全に現行版へ戻したい |

- 層1が最速。Netlify は過去のデプロイをすべて保持しており、ワンクリックで公開デプロイを切り替えられる。
  **ただし切り戻し先が static-only デプロイ（2026-08-30 の4件など）だと Functions が消える。**
  Publish 後は必ず `bash scripts/verify-prod-deploy.sh` を実行すること。
- 層3の復元点はタグ `baseline-v1-2026-07-07`（commit e75e7ee）。`release/` の成果物に依存しない。

---

## コミット ↔ 本番の対応ルール

- 本番に上げた ref には必ず `deploy/YYYY-MM-DD-n` タグを打つ（GitHub 上で本番履歴が一覧できる）
- `docs/DEPLOY-LOG.md` が台帳。「いつ / どのコミット / 何を変えた / 誰が確認したか」を1行で残す
- 本番の実体確認はいつでも `curl https://noa-place.co.jp/deploy-info.json`
- ブランチ運用: 開発は `redesign/v2`（以降は機能ごとに `redesign/v2-<機能名>` でも可）。
  本番採用が確定したら `main` へマージし、以後 `main` = 本番相当を維持する

## 本番を壊さないための注意点

- **netlify.toml は手動デプロイでは読まれない** → パッケージに `_redirects` / `_headers` を自動同梱済み（スクリプトが生成）。SPA リダイレクトとセキュリティヘッダはこれで担保される
- **ブラウザDropは Functions を配備できない** → slack.js / notion-intake.js が本番から消え、しかも通知先 URL には SPA キャッチオールにより **200 で index.html が返るため、通知失敗がどこにも表面化しない**（2026-07-08 と 2026-08-30 に実際に発生）。本番反映は必ず `scripts/deploy-prod.sh` を使うこと。Guard R4 がこの状態を検知する
- **SLACK_WEBHOOK_URL / NOTION_TOKEN / NOTION_INTAKE_DB_ID** が Netlify UI（Site configuration → Environment variables）に設定されていないと、function は配備されても失敗する。ローテーション時もコード変更不要・UI 変更のみ。値は `netlify env:get` ではマスクされるため、確認は `netlify dev:exec` 経由で行う（値を出力しないこと）
- Netlify 管理画面上でのファイル直編集・フォルダの直接ドロップは**禁止**（本番・プレビューとも `scripts/` 経由に一本化）
- パッケージ生成元の ref が GitHub に push 済みであることを常に確認（ローカルにしかないコミットを本番化しない）
- `release/` は git 管理外。台帳とタグが対応関係の記録
- `release/` に残るのは `PREVIEW_ONLY_*` のみ（本番用パッケージは deploy 成功時に自動削除される）

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

---

## 既知の課題（別Issue候補・今回は未対応）

| 項目 | 内容 |
|---|---|
| Notion に会社名が保存されない | 問い合わせフォームの `company` は Netlify Forms には保存されるが、`notion-intake.js` の `buildProperties` に会社名プロパティのマッピングが無いため Notion DB へ書かれない。2026-09-03 の Backfill でも同じ理由で未記録。対応には Notion DB 側のプロパティ追加とマッピング追加が必要 |
| Notion Integration の権限 | Read + Insert のみで Update 権限が無いため、API からページのアーカイブ（削除）ができない。登録動作には影響しないが、テスト行の後始末は手動になる |
| ~~Webhook URL が検証されない~~ | **RESOLVED（2026-09-04）**。`verify-prod-deploy.sh` の `[6/6] WEBHOOK_CONFIGURATION` Gate が Netlify UI の hook 設定を `prod-site.conf` の期待値と突き合わせる。旧 direct path・無効化・重複・別 form・別ホスト・path typo をすべて `WEBHOOK_CONFIGURATION_MISMATCH` で検知する |
| ~~SPA catch-all が未配備 function を隠す~~ | **RESOLVED（2026-09-04）**。`/.netlify/*` へは redirect を書けないことが判明したため、catch-all の除外ではなく `/hooks/*` エイリアス経由へ Webhook を移行して解決した。**Function 未配備時、Webhook が叩くパスは 4xx を返す。** 直接パス `/.netlify/functions/*` は依然 200 + HTML を返すが、Webhook はそこを使わない。Guard は `/hooks/*` を主判定にしている |
