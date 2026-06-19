// Supabase Edge Function: signup-request
// Public "request access" form from the login screen (UNAUTHENTICATED).
// Validates the submitted details and emails them to the super-admin inbox.
//
// Deploy:   supabase functions deploy signup-request
// Secrets:  GMAIL_USER, GMAIL_APP_PASSWORD  (already set)
//           SIGNUP_NOTIFY_EMAIL  (optional; where requests are sent.
//                                 Defaults to GMAIL_USER if unset.)

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

function esc(s: unknown): string {
  return String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" } as Record<string, string>)[c]
  );
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const body = await req.json().catch(() => ({}));
    const name = (body.name ?? "").toString().trim();
    const orgName = (body.orgName ?? "").toString().trim();
    const contact = (body.contact ?? "").toString().trim();
    const email = (body.email ?? "").toString().trim();
    const industry = (body.industry ?? "").toString().trim();

    if (!name || !orgName || !email) {
      return json({ error: "name, orgName and email are required" }, 400);
    }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return json({ error: "invalid email" }, 400);
    }

    const gmailUser = Deno.env.get("GMAIL_USER")!;
    const gmailPass = Deno.env.get("GMAIL_APP_PASSWORD")!;
    const notify = Deno.env.get("SIGNUP_NOTIFY_EMAIL") || gmailUser;

    const rows: [string, string][] = [
      ["Name", name],
      ["Organization", orgName],
      ["Contact number", contact || "-"],
      ["Email", email],
      ["Industry", industry || "-"],
    ];
    const text = "New access request\n\n" +
      rows.map(([k, v]) => `${k}: ${v}`).join("\n") +
      "\n\nSubmitted from the Opstation login page.";
    const html = `<div style="font-family:-apple-system,Arial,sans-serif;font-size:14px;color:#1a1a1a">
  <h2 style="margin:0 0 12px">New access request</h2>
  <table style="border-collapse:collapse">
    ${rows.map(([k, v]) => `<tr><td style="padding:4px 16px 4px 0;color:#888">${esc(k)}</td><td style="padding:4px 0;font-weight:600">${esc(v)}</td></tr>`).join("")}
  </table>
  <p style="color:#888;margin-top:16px">Submitted from the Opstation login page. Reply directly to reach the requester.</p>
</div>`;

    const client = new SMTPClient({
      connection: {
        hostname: "smtp.gmail.com",
        port: 465,
        tls: true,
        auth: { username: gmailUser, password: gmailPass },
      },
    });
    await client.send({
      from: `Opstation <${gmailUser}>`,
      to: notify,
      replyTo: email,
      subject: `Access request: ${orgName}`,
      content: text,
      html,
    });
    await client.close();

    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
