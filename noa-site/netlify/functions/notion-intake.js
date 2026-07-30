// netlify/functions/notion-intake.js
// -----------------------------------------------------------------------------
// 問い合わせを Notion DB へ自動登録する Netlify Function。
//
// 【設計方針】
// - 既存の slack.js は一切変更しない。この関数は Netlify Forms の
//   「2つ目の Outgoing webhook」として独立に発火する。
//   → Notion が落ちてもユーザーへの送信成功レスポンス・Slack通知の
//     どちらもブロックしない（関数同士が完全に分離されている）。
// - Notion 失敗時は既存の Slack 経路(SLACK_WEBHOOK_URL)へ警告を出す。
// - 認証情報は process.env のみから参照する（ハードコード禁止）。
// - 依存追加なし。標準 fetch のみ（Node 18+ / Netlify Functions）。
//
// 【必要な環境変数】
//   NOTION_TOKEN         ... Notion internal integration token
//   NOTION_INTAKE_DB_ID  ... 登録先データベースID（32桁）
//   SLACK_WEBHOOK_URL    ... 失敗時の警告通知用（既存・任意）
//
// 【Netlify 側の設定】
//   Site configuration → Notifications → Emails and webhooks
//     → Add notification → Outgoing webhook
//        Event: New form submission / Form: contact
//        URL:   https://noa-place.co.jp/.netlify/functions/notion-intake
//   ※ 既存の slack への webhook は残したまま、追加で登録すること。
//
// 【検証用 curl】(本番/ローカルどちらでも。ローカルは netlify dev で :8888)
//   curl -i -X POST https://noa-place.co.jp/.netlify/functions/notion-intake \
//     -H 'Content-Type: application/json' \
//     -d '{"payload":{"data":{
//           "name":"テスト太郎",
//           "email":"test@example.com",
//           "company":"株式会社テスト",
//           "subject":"web",
//           "message":"curl からの疎通確認です。"
//         }}}'
//   期待値: 200 {"ok":true,...} / Notion DB に1件追加される
//   ※ GET でアクセスした場合は 405（配備確認用。空データ登録を防ぐガード）
// -----------------------------------------------------------------------------

const NOTION_API = "https://api.notion.com/v1/pages";
const NOTION_VERSION = "2022-06-28";
const TIMEOUT_MS = 5000;
const MAX_RETRY = 2; // 429 / 5xx のみ、指数バックオフで最大2回
const TEXT_LIMIT = 2000; // Notion rich_text の1ブロック上限

// ---------------------------------------------------------------------------
// ホワイトリスト変換
//   select に未定義の名前を送ると選択肢が勝手に増えて表記ゆれでDBが壊れるため、
//   必ずこの関数を通し、マッチしない場合はフォールバック値へ寄せる。
// ---------------------------------------------------------------------------
const STATUS_ALLOWED = [
  "いますぐ転職を考えている",
  "3ヶ月以内に転職したい",
  "良い求人があれば検討したい",
  "情報収集中",
  "未入力",
];
const STATUS_FALLBACK = "未入力";

const INQUIRY_ALLOWED = [
  "求職相談",
  "採用支援の相談",
  "制作・開発の相談",
  "採用応募",
  "営業・提携",
  "その他",
];
const INQUIRY_FALLBACK = "その他";

// フォーム実値 → 問い合わせ種別
// HPフォームの select[name=subject] の実値は hr / web / marketing / other
const INQUIRY_MAP = {
  career: "求職相談",
  job: "求職相談",
  recruit: "採用支援の相談",
  hr: "採用支援の相談",
  dev: "制作・開発の相談",
  web: "制作・開発の相談",
  marketing: "制作・開発の相談",
  apply: "採用応募",
  sales: "営業・提携",
  partner: "営業・提携",
  other: "その他",
  不明: "その他",
};

const SERVICE_ALLOWED = [
  "SIMPLE CAREER",
  "採用支援",
  "Web・制作・開発",
  "マーケティング",
  "HaboR",
  "その他・不明",
];
const SERVICE_FALLBACK = "その他・不明";

// フォーム実値 → 対象サービス（HP。LPは常に SIMPLE CAREER）
const SERVICE_MAP = {
  hr: "採用支援",
  recruit: "採用支援",
  career: "SIMPLE CAREER",
  job: "SIMPLE CAREER",
  web: "Web・制作・開発",
  dev: "Web・制作・開発",
  marketing: "マーケティング",
  habor: "HaboR",
  other: "その他・不明",
};

function normalizeKey(v) {
  return String(v == null ? "" : v).trim();
}

/** 許容値に完全一致すればそれを、マップに当たれば変換値を、なければフォールバック */
function toSelect(raw, allowed, map, fallback) {
  const v = normalizeKey(raw);
  if (!v) return fallback;
  if (allowed.includes(v)) return v; // 既に正式な選択肢名
  const hit = map[v.toLowerCase()] || map[v];
  if (hit && allowed.includes(hit)) return hit;
  return fallback;
}

const toCurrentStatus = (raw) =>
  toSelect(raw, STATUS_ALLOWED, {}, STATUS_FALLBACK);

const toInquiryType = (raw) =>
  toSelect(raw, INQUIRY_ALLOWED, INQUIRY_MAP, INQUIRY_FALLBACK);

/** LPは常に SIMPLE CAREER、HPは問い合わせ種別(subject実値)から判定 */
function toTargetService(rawSubject, source) {
  if (source === "LP") return "SIMPLE CAREER";
  return toSelect(rawSubject, SERVICE_ALLOWED, SERVICE_MAP, SERVICE_FALLBACK);
}

// ---------------------------------------------------------------------------
// 値の整形ヘルパー
// ---------------------------------------------------------------------------
const clip = (s, n = TEXT_LIMIT) => String(s).slice(0, n);

/** JST(+09:00)オフセット付き ISO 8601 */
function nowJstIso(d = new Date()) {
  const jst = new Date(d.getTime() + 9 * 60 * 60 * 1000);
  const p = (n, w = 2) => String(n).padStart(w, "0");
  return (
    `${jst.getUTCFullYear()}-${p(jst.getUTCMonth() + 1)}-${p(jst.getUTCDate())}` +
    `T${p(jst.getUTCHours())}:${p(jst.getUTCMinutes())}:${p(jst.getUTCSeconds())}+09:00`
  );
}

/** 個人情報をログに残さないためのマスク */
function maskEmail(v) {
  const s = normalizeKey(v);
  if (!s || !s.includes("@")) return s ? "***" : "";
  const [l, d] = s.split("@");
  return `${l.slice(0, 1)}***@${d}`;
}
function maskPhone(v) {
  const s = normalizeKey(v).replace(/[^\d]/g, "");
  return s ? `***${s.slice(-3)}` : "";
}

// ---------------------------------------------------------------------------
// プロパティのマッピング
//   担当者 / 初回対応日時 / 対応メモ / 候補者DBへ登録済 は人間が手で埋めるため
//   APIからは送らない。
// ---------------------------------------------------------------------------
function buildProperties(data, source, receivedAt) {
  const name = normalizeKey(data.name || data["氏名"] || data.fullname);
  const email = normalizeKey(data.email || data["メールアドレス"]);
  const phone = normalizeKey(data.phone || data.tel || data["電話番号"]);
  const ageRaw = data.age != null ? data.age : data["年齢"];
  const currentJob = normalizeKey(data.current_job || data["現在の職種"]);
  const desiredJob = normalizeKey(data.desired_job || data["希望職種"]);
  const situation = data.situation != null ? data.situation : data["現在の状況"];
  const subject = data.subject != null ? data.subject : data["問い合わせ種別"];
  const message = normalizeKey(
    data.message || data["相談内容・メッセージ"] || data.body
  );

  const props = {};

  // 氏名(title): 空ならメール、それも無ければ固定文言
  props["氏名"] = {
    title: [{ text: { content: clip(name || email || "（氏名未入力）", 200) } }],
  };

  // 空文字は Notion がエラーにするため、値が無ければキーごと省略する
  if (email) props["メールアドレス"] = { email };
  if (phone) props["電話番号"] = { phone_number: phone };

  // Number("") は 0 になるため、数字が1文字も無い場合は明確に NaN 扱いにする。
  // （そうしないと年齢欄が無いHPフォームで 0 が登録されてしまう）
  const ageDigits = String(ageRaw == null ? "" : ageRaw).replace(/[^\d.-]/g, "").trim();
  const age = ageDigits === "" ? NaN : Number(ageDigits);
  if (Number.isFinite(age)) props["年齢"] = { number: age };

  if (currentJob)
    props["現在の職種"] = {
      rich_text: [{ text: { content: clip(currentJob) } }],
    };
  if (desiredJob)
    props["希望職種"] = {
      rich_text: [{ text: { content: clip(desiredJob) } }],
    };

  props["現在の状況"] = { select: { name: toCurrentStatus(situation) } };
  props["問い合わせ種別"] = { select: { name: toInquiryType(subject) } };

  if (message)
    props["相談内容・メッセージ"] = {
      rich_text: [{ text: { content: clip(message) } }],
    };

  props["流入元"] = {
    select: {
      name: source === "LP" ? "LP問い合わせフォーム" : "HP問い合わせフォーム",
    },
  };
  props["対象サービス"] = {
    select: { name: toTargetService(subject, source) },
  };
  props["受信日時"] = { date: { start: receivedAt } };
  props["対応ステータス"] = { status: { name: "未対応" } };

  return props;
}

// ---------------------------------------------------------------------------
// Notion 送信（5秒タイムアウト + 429/5xx のみ指数バックオフ最大2回）
// ---------------------------------------------------------------------------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function postToNotion(body, token) {
  let lastErr = null;

  for (let attempt = 0; attempt <= MAX_RETRY; attempt++) {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), TIMEOUT_MS);
    try {
      const res = await fetch(NOTION_API, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Notion-Version": NOTION_VERSION,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        signal: ac.signal,
      });

      if (res.ok) {
        const json = await res.json().catch(() => ({}));
        return { ok: true, id: json.id, attempts: attempt + 1 };
      }

      const detail = clip(await res.text().catch(() => ""), 500);

      // 400系はリクエスト自体の誤り。リトライせず即座に確定させ、ログに出す。
      if (res.status !== 429 && res.status < 500) {
        console.error(
          `[notion-intake] Notion ${res.status} (client error, no retry): ${detail}`
        );
        return { ok: false, status: res.status, detail, attempts: attempt + 1 };
      }

      // 429 / 5xx のみリトライ対象
      lastErr = `Notion ${res.status}: ${detail}`;
      if (attempt < MAX_RETRY) {
        const wait = 400 * Math.pow(2, attempt); // 400ms, 800ms
        console.warn(
          `[notion-intake] ${lastErr} — retry ${attempt + 1}/${MAX_RETRY} in ${wait}ms`
        );
        await sleep(wait);
        continue;
      }
      return { ok: false, status: res.status, detail, attempts: attempt + 1 };
    } catch (e) {
      const aborted = e && e.name === "AbortError";
      lastErr = aborted ? `timeout after ${TIMEOUT_MS}ms` : String(e && e.message ? e.message : e);
      if (attempt < MAX_RETRY) {
        const wait = 400 * Math.pow(2, attempt);
        console.warn(
          `[notion-intake] ${lastErr} — retry ${attempt + 1}/${MAX_RETRY} in ${wait}ms`
        );
        await sleep(wait);
        continue;
      }
      return { ok: false, detail: lastErr, attempts: attempt + 1 };
    } finally {
      clearTimeout(timer);
    }
  }
  return { ok: false, detail: lastErr || "unknown" };
}

/** 既存のSlack経路へ「手動対応が必要」を通知（失敗しても握りつぶす） */
async function notifySlackFailure(summary) {
  const webhook = process.env.SLACK_WEBHOOK_URL;
  if (!webhook) return;
  const text =
    `⚠️ Notionへの問い合わせ登録に失敗しました。手動で追加してください\n` +
    `• 氏名: ${summary.name || "(no name)"}\n` +
    `• メール: ${summary.emailMasked || "(no email)"}\n` +
    `• 種別: ${summary.inquiry}\n` +
    `• 流入元: ${summary.source}\n` +
    `• 受信日時: ${summary.receivedAt}\n` +
    `• 理由: ${summary.reason}`;
  try {
    await fetch(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
  } catch (e) {
    console.error("[notion-intake] Slack fallback failed:", e && e.message);
  }
}

// ---------------------------------------------------------------------------
// handler
// ---------------------------------------------------------------------------
exports.handler = async (event) => {
  // GETでの疎通確認時に空データを登録しないためのガード（405=配備済みの確認）
  if (event.httpMethod !== "POST") {
    return { statusCode: 405, body: "Method Not Allowed" };
  }

  const receivedAt = nowJstIso();

  const token = process.env.NOTION_TOKEN;
  const dbId = process.env.NOTION_INTAKE_DB_ID;
  if (!token || !dbId) {
    console.error("[notion-intake] Missing NOTION_TOKEN or NOTION_INTAKE_DB_ID");
    // 設定漏れもSlackへ出して取りこぼしを防ぐ
    await notifySlackFailure({
      name: "(設定エラー)",
      emailMasked: "",
      inquiry: "-",
      source: "-",
      receivedAt,
      reason: "NOTION_TOKEN / NOTION_INTAKE_DB_ID が未設定",
    });
    return { statusCode: 200, body: JSON.stringify({ ok: false, reason: "env missing" }) };
  }

  let data = {};
  let source = "HP";
  try {
    const incoming = JSON.parse(event.body || "{}");
    // Netlify Forms の通知payloadは形が揺れるので広めに拾う（slack.js と同方針）
    data =
      incoming?.payload?.data ||
      incoming?.data ||
      incoming?.form_submission?.data ||
      incoming ||
      {};

    // 流入元判定: 明示指定 > フォーム名 > 既定(HP)
    const formName = normalizeKey(
      incoming?.payload?.form_name || incoming?.form_name || data["form-name"]
    );
    const explicit = normalizeKey(data.source || data["流入元"]);
    if (/^lp$/i.test(explicit) || /LP問い合わせ/.test(explicit)) source = "LP";
    else if (/simple[\s_-]*career|^lp[-_]/i.test(formName)) source = "LP";
  } catch (e) {
    console.error("[notion-intake] Invalid JSON body:", e && e.message);
    return { statusCode: 400, body: "Invalid JSON" };
  }

  const properties = buildProperties(data, source, receivedAt);
  const result = await postToNotion(
    { parent: { database_id: dbId }, properties },
    token
  );

  // ログには個人情報の全文を出さない
  const logSummary = {
    source,
    inquiry: properties["問い合わせ種別"].select.name,
    service: properties["対象サービス"].select.name,
    name: properties["氏名"].title[0].text.content,
    email: maskEmail(data.email || data["メールアドレス"]),
    phone: maskPhone(data.phone || data.tel || data["電話番号"]),
  };

  if (result.ok) {
    console.log(
      `[notion-intake] created page (attempts=${result.attempts})`,
      JSON.stringify(logSummary)
    );
    return { statusCode: 200, body: JSON.stringify({ ok: true, id: result.id }) };
  }

  console.error(
    `[notion-intake] FAILED (attempts=${result.attempts})`,
    JSON.stringify({ ...logSummary, status: result.status, detail: result.detail })
  );
  await notifySlackFailure({
    name: logSummary.name,
    emailMasked: logSummary.email,
    inquiry: logSummary.inquiry,
    source,
    receivedAt,
    reason: `${result.status || ""} ${result.detail || ""}`.trim(),
  });

  // Netlify Forms 側のwebhookを再送ループさせないため 200 を返す
  // （ユーザー体験には一切影響しない経路。取りこぼしはSlack警告で担保）
  return { statusCode: 200, body: JSON.stringify({ ok: false }) };
};

// テスト用に純粋関数を公開（テストランナー未導入のため実行はされない）
exports._internal = {
  toCurrentStatus,
  toInquiryType,
  toTargetService,
  buildProperties,
  nowJstIso,
  maskEmail,
  maskPhone,
};
