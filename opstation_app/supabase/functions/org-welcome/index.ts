// supabase/functions/org-welcome/index.ts
// Sends a welcome email with the Opstation onboarding guide PDF attached to a
// new organization's master admin. Triggered by a DB trigger (pg_net) on master
// admin creation, or callable directly with functions.invoke('org-welcome', ...).
//
// Deploy: supabase functions deploy org-welcome --no-verify-jwt
// Secrets used: GMAIL_USER, GMAIL_APP_PASSWORD, WELCOME_SECRET
//   (WELCOME_SECRET is dedicated to this function and independent of the
//    CRON_SECRET used by daily-backup, so the two never interfere.)
// Optional env: ONBOARDING_PDF_URL (defaults to the live landing copy),
//               APP_LOGIN_URL (defaults to the app URL).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";
import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), {
    status,
    headers: { "content-type": "application/json" },
  });

serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  // Shared-secret auth (the DB trigger sends this header). Dedicated secret.
  const secret = Deno.env.get("WELCOME_SECRET");
  if (secret && req.headers.get("x-welcome-secret") !== secret) {
    return json({ error: "unauthorized" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }

  const email = String(body.email ?? "").trim();
  const name = String(body.name ?? "").trim();
  const orgName = String(body.orgName ?? "").trim();
  const greeting = name || "there";
  if (!email || !email.includes("@")) {
    return json({ error: "valid email required" }, 400);
  }

  const GMAIL_USER = Deno.env.get("GMAIL_USER");
  const GMAIL_PASS = Deno.env.get("GMAIL_APP_PASSWORD");
  if (!GMAIL_USER || !GMAIL_PASS) {
    return json({ error: "smtp not configured" }, 500);
  }

  const pdfUrl =
    Deno.env.get("ONBOARDING_PDF_URL") ??
    "https://opstation-landing.web.app/opstation-onboarding-guide.pdf";
  const loginUrl =
    Deno.env.get("APP_LOGIN_URL") ?? "https://opstation-f06c7.web.app";

  // Fetch the onboarding PDF and attach it (attachment is best-effort).
  let attachments: Array<Record<string, string>> = [];
  let attached = false;
  try {
    const r = await fetch(pdfUrl);
    if (r.ok) {
      const buf = new Uint8Array(await r.arrayBuffer());
      // Guard against very large files (Gmail ~25MB; stay well under).
      if (buf.byteLength <= 20 * 1024 * 1024) {
        attachments = [
          {
            filename: "Opstation-Onboarding-Guide.pdf",
            content: encodeBase64(buf),
            encoding: "base64",
            contentType: "application/pdf",
          },
        ];
        attached = true;
      }
    }
  } catch (_) {
    // proceed without attachment; the email still links the guide
  }

  const orgBit = orgName ? ` for ${orgName}` : "";
  // ASCII-only subject (denomailer 1.6.0 mis-folds long non-ASCII subjects).
  const subject = "Welcome to Opstation ERP";

  const html = `<!doctype html>
<html><body style="margin:0;background:#f6f8fc;font-family:Arial,Helvetica,sans-serif;color:#0f1729;">
  <div style="max-width:560px;margin:0 auto;padding:28px 22px;">
    <div style="font-weight:800;font-size:18px;color:#2f6fed;letter-spacing:.3px;">OPSTATION ERP</div>
    <div style="height:3px;background:#2f6fed;width:46px;border-radius:3px;margin:8px 0 22px;"></div>
    <h1 style="font-size:21px;margin:0 0 6px;">Welcome aboard, ${greeting}.</h1>
    <p style="font-size:14px;line-height:1.55;color:#39414f;margin:0 0 16px;">
      Your Opstation workspace${orgBit} is ready. Opstation unifies inventory, sales,
      POS, manufacturing, financials, facilities and field operations across every
      branch &mdash; with real-time visibility at every stage.
    </p>
    <p style="font-size:14px;line-height:1.55;color:#39414f;margin:0 0 18px;">
      We have attached an <b>Onboarding Guide</b> (PDF) covering every module,
      voucher and report, plus a recommended setup order to get you started.
    </p>
    <a href="${loginUrl}" style="display:inline-block;background:#2f6fed;color:#fff;
       text-decoration:none;font-weight:700;font-size:14px;padding:11px 20px;border-radius:8px;">
      Sign in to your panel
    </a>
    <p style="font-size:12.5px;line-height:1.5;color:#5b6473;margin:22px 0 0;">
      Tip: the same guide is always available inside the panel under
      <b>ERP &rsaquo; Onboarding Guide</b>.
    </p>
    <div style="border-top:1px solid #e6eaf2;margin:24px 0 0;padding-top:14px;font-size:12px;color:#8a93a3;">
      Opstation ERP &mdash; your journey from purchase to profit.
    </div>
  </div>
</body></html>`;

  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: { username: GMAIL_USER, password: GMAIL_PASS },
    },
  });

  try {
    await client.send({
      from: `Opstation <${GMAIL_USER}>`,
      to: email,
      subject,
      html,
      attachments,
    });
  } catch (e) {
    try {
      await client.close();
    } catch (_) {
      // ignore
    }
    return json({ error: "send failed", detail: String(e) }, 500);
  }

  try {
    await client.close();
  } catch (_) {
    // ignore
  }

  return json({ status: "sent", to: email, attached });
});
