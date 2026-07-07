// netlify/functions/slack.js
exports.handler = async (event) => {
    try {
      const webhook = process.env.SLACK_WEBHOOK_URL;
      if (!webhook) return { statusCode: 500, body: "Missing SLACK_WEBHOOK_URL" };
  
      const incoming = JSON.parse(event.body || "{}");
  
      // Netlify Forms の通知payloadは形が揺れるので広めに拾う
      const data =
        incoming?.payload?.data ||
        incoming?.data ||
        incoming?.form_submission?.data ||
        incoming;
  
      const name = data?.name || "(no name)";
      const email = data?.email || "(no email)";
      const subject = data?.subject || "";
      const message = data?.message || "";
  
      const text =
        `📩 *New Contact Submission*\n` +
        `• Name: ${name}\n` +
        `• Email: ${email}\n` +
        (subject ? `• Type: ${subject}\n` : "") +
        `• Message:\n${message}`;
  
      const res = await fetch(webhook, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text }),
      });
  
      if (!res.ok) {
        const t = await res.text().catch(() => "");
        return { statusCode: 500, body: `Slack error: ${res.status} ${t}` };
      }
  
      return { statusCode: 200, body: "ok" };
    } catch (e) {
      return { statusCode: 500, body: `Error: ${e?.message || e}` };
    }
  };