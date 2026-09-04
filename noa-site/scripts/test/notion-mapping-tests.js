#!/usr/bin/env node
/**
 * notion-intake.js の buildProperties() 単体テスト
 *
 *   node scripts/test/notion-mapping-tests.js
 *
 * Notion API にも Netlify にも接続しない。本番の実装ファイルをそのまま
 * require し、_internal 経由で純粋にプロパティ生成だけを検証する。
 * 依存パッケージは追加しない（素の node のみ）。
 */
const path = require("path");
const { buildProperties, nowJstIso } = require(
  path.join(__dirname, "..", "..", "netlify", "functions", "notion-intake.js")
)._internal;

const RECEIVED = nowJstIso(new Date("2026-09-04T00:00:00.000Z"));
let pass = 0, fail = 0;

const check = (label, cond, detail) => {
  if (cond) { console.log(`  ✅ ${label}`); pass++; }
  else { console.log(`  ❌ ${label}${detail ? "  → " + detail : ""}`); fail++; }
};
const rich = (props, key) =>
  props[key] ? props[key].rich_text[0].text.content : undefined;

// 既存マッピングが変わっていないことの基準（回帰検出用）
const BASE_KEYS = [
  "氏名", "メールアドレス", "現在の状況", "問い合わせ種別",
  "相談内容・メッセージ", "流入元", "対象サービス", "受信日時", "対応ステータス",
];

console.log("==============================================");
console.log(" notion-intake buildProperties tests");
console.log("==============================================\n");

// ---- CASE 1: company あり → 会社名 property が付く ----
console.log("CASE 1  company あり");
{
  const p = buildProperties(
    { name: "テスト太郎", email: "t@example.com", company: "株式会社テスト・カンパニー", subject: "hr", message: "本文" },
    "HP", RECEIVED
  );
  check("会社名 property が存在する", "会社名" in p);
  check("値が一致する", rich(p, "会社名") === "株式会社テスト・カンパニー", rich(p, "会社名"));
  check("type は rich_text", !!(p["会社名"] && p["会社名"].rich_text));
}

// ---- CASE 2: company = "" → 送信しない ----
console.log("\nCASE 2  company = 空文字");
{
  const p = buildProperties(
    { name: "テスト太郎", email: "t@example.com", company: "", subject: "hr", message: "本文" },
    "HP", RECEIVED
  );
  check("会社名 property を送信しない（空文字は Notion がエラーにする）", !("会社名" in p));
  check("他の必須プロパティは揃っている", BASE_KEYS.every((k) => k in p));
}

// ---- CASE 3: company undefined → 送信しない ----
console.log("\nCASE 3  company undefined");
{
  const p = buildProperties(
    { name: "テスト太郎", email: "t@example.com", subject: "hr", message: "本文" },
    "HP", RECEIVED
  );
  check("会社名 property を送信しない", !("会社名" in p));
  check("他の必須プロパティは揃っている", BASE_KEYS.every((k) => k in p));
  check("company: null でも同様", !("会社名" in buildProperties({ name: "A", company: null }, "HP", RECEIVED)));
}

// ---- CASE 4: 前後空白 → trim ----
console.log("\nCASE 4  前後空白");
{
  const p = buildProperties({ name: "A", company: "  株式会社ノア  " }, "HP", RECEIVED);
  check("trim される", rich(p, "会社名") === "株式会社ノア", JSON.stringify(rich(p, "会社名")));
  check("空白のみは未設定扱い", !("会社名" in buildProperties({ name: "A", company: "   " }, "HP", RECEIVED)));
}

// ---- CASE 5: 日本語・中黒・全角記号 ----
console.log("\nCASE 5  日本語・中黒・全角記号");
{
  const names = [
    "株式会社テスト・カンパニー",
    "株式会社テスト･カンパニー",      // 半角中黒
    "㈱ノア＆カンパニー（東京）",
    "noa Inc. ／ 株式会社noa",
    "有限会社ＡＢＣ－１２３",
  ];
  names.forEach((n) => {
    const p = buildProperties({ name: "A", company: n }, "HP", RECEIVED);
    check(`破損しない: ${n}`, rich(p, "会社名") === n, rich(p, "会社名"));
  });
  const long = "あ".repeat(2500);
  const p = buildProperties({ name: "A", company: long }, "HP", RECEIVED);
  check("2000字上限で clip される", rich(p, "会社名").length === 2000, String(rich(p, "会社名").length));
  check("会社名（日本語キー）でも拾う", rich(buildProperties({ name: "A", "会社名": "株式会社ノア" }, "HP", RECEIVED), "会社名") === "株式会社ノア");
}

// ---- CASE 6: 既存 HP マッピングの regression ----
console.log("\nCASE 6  既存 HP マッピングの regression");
{
  const data = { name: "山田 太郎", email: "x@example.com", company: "株式会社テスト・カンパニー", subject: "hr", message: "ご相談" };
  const p = buildProperties(data, "HP", RECEIVED);
  check("氏名", p["氏名"].title[0].text.content === "山田 太郎");
  check("メールアドレス", p["メールアドレス"].email === "x@example.com");
  check("問い合わせ種別 = 採用支援の相談", p["問い合わせ種別"].select.name === "採用支援の相談");
  check("対象サービス = 採用支援", p["対象サービス"].select.name === "採用支援");
  check("流入元 = HP問い合わせフォーム", p["流入元"].select.name === "HP問い合わせフォーム");
  check("対応ステータス = 未対応", p["対応ステータス"].status.name === "未対応");
  check("相談内容・メッセージ", rich(p, "相談内容・メッセージ") === "ご相談");
  check("受信日時は引数のまま", p["受信日時"].date.start === RECEIVED);
  check("年齢は送信されない（HPに年齢欄は無い）", !("年齢" in p));
  check("既存キーは会社名を除き従来どおり", BASE_KEYS.every((k) => k in p));
  const withoutCompany = buildProperties({ ...data, company: undefined }, "HP", RECEIVED);
  const diff = Object.keys(p).filter((k) => !(k in withoutCompany));
  check("company の有無で増えるキーは 会社名 のみ", diff.length === 1 && diff[0] === "会社名", JSON.stringify(diff));
}

// ---- CASE 7: LP payload の regression ----
console.log("\nCASE 7  LP payload の regression");
{
  const p = buildProperties(
    { name: "佐藤 花子", email: "y@example.com", age: "28", current_job: "営業", desired_job: "エンジニア", message: "LPから" },
    "LP", RECEIVED
  );
  check("会社名 property を送信しない（LP に company は無い）", !("会社名" in p));
  check("流入元 = LP問い合わせフォーム", p["流入元"].select.name === "LP問い合わせフォーム");
  check("対象サービス = SIMPLE CAREER", p["対象サービス"].select.name === "SIMPLE CAREER");
  check("年齢 = 28", p["年齢"].number === 28);
  check("現在の職種", rich(p, "現在の職種") === "営業");
  check("希望職種", rich(p, "希望職種") === "エンジニア");
  const lpWithCompany = buildProperties({ name: "A", company: "株式会社テスト" }, "LP", RECEIVED);
  check("LP でも company が来れば保存する（将来 LP に欄が増えても壊れない）", rich(lpWithCompany, "会社名") === "株式会社テスト");
}

console.log("\n==============================================");
console.log(` PASS=${pass}  FAIL=${fail}`);
console.log("==============================================");
if (fail > 0) process.exit(1);
console.log(" ALL_TESTS_PASS");
