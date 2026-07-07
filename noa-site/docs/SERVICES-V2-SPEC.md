# SERVICES v2 設計仕様書（Phase 2 実装前確定版）

作成日: 2026-07-07 / 対象: トップページ `#svcs` セクション + サービス詳細への遷移
フラグ: `SITE_FLAGS.services: 'v1' | 'v2'`（v1 = 現行3行リスト）

---

## 1. 設計の目的

現行の SERVICES は「番号 + 英語タイトル + 矢印」の3行のみ。上品だが、
**(a) 何ができる会社か伝わらない (b) 詳細ページへ進む動機が弱い (c) WEBサービス企業としての証明がない**。

SERVICES v2 の役割は1つ: **サービス詳細ページへの遷移率を最大化すること**。
詳細ページには既に優秀な説得構造（課題チェックリスト→フロー→事例→FAQ→CTA）があり、
詳細ページ到達が問い合わせの最大の予測因子になる。トップで説明しすぎない。**トップは「予告編」、詳細が「本編」**。

## 2. 行の構造（Expanding Row）

現行の「行」フォーマットは維持する（リスト構造は noa のエディトリアル言語に合っている）。
変えるのは行の**情報密度と応答**。

```
[デフォルト状態 — 現行とほぼ同じ静けさ]
01   HUMAN RESOURCES                                   HR事業   ↗

[ホバー / フォーカス時 — 行が「呼吸」して開く]
01   HUMAN RESOURCES                                   HR事業   ↗
     ┌────────────────────────────────────────────────────┐
     │ 採用の入口から定着まで、仕組みごと設計する。            │  ← 一行の価値提案
     │ #人材紹介  #採用戦略設計  #採用オペレーション          │  ← 提供領域タグ×3
     │                                    [キービジュアル断片] │  ← 右端に画像(既存 s.img を流用)
     └────────────────────────────────────────────────────┘
```

- **開閉**: `grid-template-rows: 0fr → 1fr` + opacity。duration 0.7s / `--ease-noa`。高さアニメは grid 方式で reflow 負荷を回避。
- **モバイル**: ホバーが存在しないため**最初から半開き**（価値提案1行 + タグのみ、画像なし）。タップで即詳細へ。
- **キーボード**: 行は `<a href="?page=services&service=hr">` 化し、`:focus-visible` でホバーと同じ展開。
- **データ**: 新規フィールドは `SVC[id].summary`（一行価値提案）と `SVC[id].tags`（詳細ページの tags を先頭3つ流用可）。既存データ構造への追加のみで、v1 レンダラーには影響しない。

## 3. 共有要素遷移（このサイト最大の見せ場）

行クリック → サービス詳細 Hero への **View Transitions API 共有要素モーフ**。

- 行内の英語タイトル（例: `HUMAN RESOURCES`）に `view-transition-name: svc-title` を**クリックされた行にのみ**動的付与。
- 詳細ページの `#sv-hero-title` に同名を付与 → ブラウザがタイトルの位置・サイズを補間し、**リストの1行がそのまま詳細ページの見出しに変形する**。
- 同様に行のキービジュアル断片 → 詳細 Hero 画像を `svc-img` で接続（第2共有要素。2つまでに制限。多いと安っぽくなる）。
- duration 0.5s / `--ease-noa`。遷移中は他要素が vtOut（既存 Phase 1 実装）で退場。
- **フォールバック**: VT 非対応（Firefox）/ reduced-motion → Phase 1 の遷移（退場フェード + 上昇リビール）に自動落下。機能は完全同一。

実装スケッチ:
```js
function showSvcV2(id, rowEl){
  if (SITE_FLAGS.services !== 'v2' || !document.startViewTransition || REDUCE_MOTION) return showSvc(id);
  rowEl.querySelector('.svc-title').style.viewTransitionName = 'svc-title';
  rowEl.querySelector('.svc-thumb')?.style.setProperty('view-transition-name', 'svc-img');
  const t = document.startViewTransition(() => showSvc(id));
  t.finished.finally(() => { /* name を除去（一意性維持のため必須） */ });
}
```

## 4. セクションヘッダの強化（軽微）

- `SERVICES` 見出しの上に現行 phil/cta と同じ**章インデックス行**を追加: `02 / Services — Chapter Two — Capabilities`（サイト全体の章体系を 01 Vision / 02 Services / 03 Company / 04 Contact に整理。現行は 01 phil / 02 cta で欠番があるため揃える）。
- 説明文の下に**中間CTA（迷い層レーン）**を1行: 「どのサービスかは、決まっていなくて大丈夫です。— 相談してみる」。`SITE_FLAGS.ctaLanes` に連動。

## 5. やらないこと（自己満足の禁止）

- カード化・グリッド化（テンプレSaaS化するため行構造を守る）
- 3D / WebGL / パララックス画像
- ホバー展開の自動再生（スクロールで勝手に開く等）— ユーザーの意図にのみ応答する
- 共有要素3つ以上のモーフ

## 6. Rollback

- 全マークアップは `renderServicesV2()` が `#svcs-list` に描画（v1 レンダラーと排他）。`SITE_FLAGS.services:'v1'` で現行レンダラーに即復帰。
- CSS は `.svc-row-v2` 名前空間に隔離。
- 章インデックス追加は `[data-variant]` 切替。

## 7. 受け入れ基準

1. 行クリック→詳細 Hero へタイトルがモーフする（Chrome/Edge/Safari）
2. Firefox / reduced-motion で機能欠損なく Phase 1 遷移に落ちる
3. モバイルで全行の価値提案+タグが見える
4. `?flags=services:v1` で現行表示に完全復帰
5. CLS 増加なし（grid 0fr→1fr 方式、画像は width/height 明示）
6. サービス詳細ページ到達率を計測イベントで v1/v2 比較できる
