// supabase/functions/punch-notify/index.ts
// Emails a per-employee notification address when that employee punches IN or
// OUT at the attendance kiosk (or any attendance write). Triggered by a DB
// trigger (pg_net) on hr_attendance INSERT/UPDATE, or callable directly with
// functions.invoke('punch-notify', ...).
//
// Deploy: supabase functions deploy punch-notify --no-verify-jwt
// Secrets used: GMAIL_USER, GMAIL_APP_PASSWORD, PUNCH_NOTIFY_SECRET
//   (PUNCH_NOTIFY_SECRET is dedicated to this function, independent of
//    WELCOME_SECRET / CRON_SECRET, so the functions never interfere.)
//
// Expected JSON body (sent by the trigger):
//   { email, employeeName, employeeCode, action: "in" | "out",
//     time: "HH:MM", date: "YYYY-MM-DD", orgName }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), {
    status,
    headers: { "content-type": "application/json" },
  });

serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  // Shared-secret auth (the DB trigger sends this header). Dedicated secret.
  const secret = Deno.env.get("PUNCH_NOTIFY_SECRET");
  if (secret && req.headers.get("x-punch-secret") !== secret) {
    return json({ error: "unauthorized" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }

  const email = String(body.email ?? "").trim();
  const employeeName = String(body.employeeName ?? "").trim() || "Employee";
  const employeeCode = String(body.employeeCode ?? "").trim();
  const action = String(body.action ?? "").trim().toLowerCase(); // "in" | "out"
  const time = String(body.time ?? "").trim();
  const date = String(body.date ?? "").trim();
  const orgName = String(body.orgName ?? "").trim();
  const branchName = String(body.branchName ?? "").trim();
  const photoUrl = String(body.photoUrl ?? "").trim();

  if (!email || !email.includes("@")) {
    return json({ error: "valid email required" }, 400);
  }
  if (action !== "in" && action !== "out") {
    return json({ error: "action must be 'in' or 'out'" }, 400);
  }

  const GMAIL_USER = Deno.env.get("GMAIL_USER");
  const GMAIL_PASS = Deno.env.get("GMAIL_APP_PASSWORD");
  if (!GMAIL_USER || !GMAIL_PASS) {
    return json({ error: "smtp not configured" }, 500);
  }

  // 24h "HH:MM" -> 12h "h:MM AM/PM"
  const to12h = (t: string): string => {
    const m = /^(\d{1,2}):(\d{2})$/.exec(t.trim());
    if (!m) return t;
    let h = parseInt(m[1], 10);
    const mm = m[2];
    const ampm = h >= 12 ? "PM" : "AM";
    h = h % 12; if (h === 0) h = 12;
    return `${h}:${mm} ${ampm}`;
  };
  const timeDisp = time ? to12h(time) : "";
  const verb = action === "in" ? "checked in" : "checked out";
  const accent = action === "in" ? "#2e9e5b" : "#2563eb";
  const codeBit = employeeCode ? ` (${employeeCode})` : "";
  const orgBranch = orgName
    ? (branchName ? `${orgName} (${branchName})` : orgName)
    : (branchName ? `(${branchName})` : "");
  // ASCII-only subject (denomailer 1.6.0 mis-folds long non-ASCII subjects).
  const subject = `${employeeName} ${verb}${timeDisp ? " at " + timeDisp : ""}`;

  const html = `<!doctype html>
<html><body style="margin:0;background:#f6f8fc;font-family:Arial,Helvetica,sans-serif;color:#0f1729;">
  <div style="max-width:520px;margin:0 auto;padding:26px 22px;">
    <div style="font-weight:800;font-size:17px;color:#2f6fed;letter-spacing:.3px;">OPSTATION ERP</div>
    <div style="height:3px;background:${accent};width:46px;border-radius:3px;margin:8px 0 20px;"></div>
    <h1 style="font-size:19px;margin:0 0 6px;">Attendance ${action === "in" ? "check-in" : "check-out"}</h1>
    <p style="font-size:14px;line-height:1.55;color:#39414f;margin:0 0 16px;">
      <b>${employeeName}</b>${codeBit} ${verb}${timeDisp ? " at <b>" + timeDisp + "</b>" : ""}${date ? " on " + date : ""}${orgBranch ? " &mdash; " + orgBranch : ""}.
    </p>
    <div style="display:inline-block;background:${accent};color:#fff;font-weight:700;font-size:14px;padding:9px 16px;border-radius:8px;">
      ${verb.toUpperCase()}${timeDisp ? "  -  " + timeDisp : ""}
    </div>
    ${photoUrl ? `<div style="margin-top:14px;">
      <a href="${photoUrl}" style="display:inline-block;background:#0f1729;color:#fff;text-decoration:none;font-weight:700;font-size:13px;padding:9px 16px;border-radius:8px;">
        View punch photo
      </a>
    </div>` : ""}
    <div style="border-top:1px solid #e6eaf2;margin:24px 0 0;padding-top:14px;font-size:12px;color:#8a93a3;">
      Automated attendance alert from Opstation ERP. You are receiving this because
      punch notifications are enabled for this employee.
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

  return json({ status: "sent", to: email, action });
});
