// Generic transactional email sender for Opstation ERP.
//
// POST { to: string | string[], subject: string, html?: string, text?: string }
// Auth: Authorization: Bearer <service role key>  (same key DB triggers already
//       use to call send-notification). Reuses the Gmail SMTP secrets that
//       punch-notify uses: GMAIL_USER, GMAIL_APP_PASSWORD.
//
// Secrets used: GMAIL_USER, GMAIL_APP_PASSWORD (already set for punch-notify).
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // Authorize: bearer must match the service role key (what DB triggers send).
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!svc || token !== svc) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }

  const rawTo = body.to;
  const to = Array.isArray(rawTo)
    ? rawTo.map((x) => String(x).trim()).filter((x) => x.includes("@"))
    : [String(rawTo ?? "").trim()].filter((x) => x.includes("@"));
  const subject = String(body.subject ?? "").trim();
  const html = body.html != null ? String(body.html) : undefined;
  const text = body.text != null ? String(body.text) : undefined;

  if (to.length === 0) return json({ error: "no valid recipients" }, 400);
  if (!subject) return json({ error: "subject required" }, 400);
  if (!html && !text) return json({ error: "html or text required" }, 400);

  const GMAIL_USER = Deno.env.get("GMAIL_USER");
  const GMAIL_PASS = Deno.env.get("GMAIL_APP_PASSWORD");
  if (!GMAIL_USER || !GMAIL_PASS) return json({ error: "smtp not configured" }, 500);

  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: { username: GMAIL_USER, password: GMAIL_PASS },
    },
  });

  try {
    // One message, all recipients in To. (Switch to a loop if you'd rather each
    // be a separate/private send.)
    await client.send({
      from: `Opstation <${GMAIL_USER}>`,
      to,
      subject,
      content: text ?? "See HTML version.",
      html: html,
    });
    await client.close();
    return json({ status: "sent", to });
  } catch (e) {
    try { await client.close(); } catch (_) { /* ignore */ }
    return json({ error: "send failed", detail: String(e) }, 500);
  }
});
