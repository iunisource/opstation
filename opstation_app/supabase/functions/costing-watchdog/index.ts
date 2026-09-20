// Costing watchdog — daily sanity check over ALL tenant orgs.
//
// Born from the Sep 2026 incident where sales posted with zero COGS for a week
// before anyone noticed (a P&L printout was the detector). This runs every
// night via pg_cron and emails each affected org's admins when any of these
// smells appear:
//   1. missing_cogs  — a locked, non-voided sales invoice, older than 3 hours,
//                      with money on it but NO 5140 (COGS) debit in any of its
//                      journal entries. The exact signature of the incident.
//   2. zero_cost_dos — a delivery-order entry posted "(zero cost)" in the last
//                      48h although its items carry delivered quantities (the
//                      lock-before-lines bug's fingerprint).
//   3. unbalanced    — any journal entry whose debits != credits (the CPV/CRV
//                      half-post signature).
//
// Detection lives in the DB function costing_watchdog_report() (migration
// 251) so the SQL can evolve without redeploying this function.
//
// Recipients: org.attendance_summary_emails (same list as the attendance
// digest). Orgs with issues but no configured list are reported in the
// response JSON ("unrouted") but no email is sent for them.
//
// Auth mirrors attendance-summary: a Bearer key that is NOT an end-user JWT
// (the cron's service key), or the shared x-cron-secret.

import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GMAIL_USER = Deno.env.get("GMAIL_USER")!;
const GMAIL_PASS = Deno.env.get("GMAIL_APP_PASSWORD")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

const enc = (s: string) => encodeURIComponent(s);
const H = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

async function rest(path: string): Promise<any[]> {
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    });
    if (!r.ok) return [];
    return await r.json();
  } catch (_) {
    return [];
  }
}

function jwtRole(token: string): string {
  try {
    const parts = token.split(".");
    if (parts.length < 2) return "";
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    b64 += "=".repeat((4 - (b64.length % 4)) % 4);
    const payload = JSON.parse(atob(b64));
    return String(payload.role ?? "");
  } catch (_) {
    return "";
  }
}

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...CORS, "content-type": "application/json" } });

const money = (n: unknown) =>
  Number(n ?? 0).toLocaleString("en-PK", { maximumFractionDigits: 2 });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const authHeader = req.headers.get("Authorization") || "";
  const bearer = authHeader.toLowerCase().startsWith("bearer ") ? authHeader.slice(7).trim() : "";
  const isUser = jwtRole(bearer) === "authenticated";
  const cronOk = (bearer !== "" && !isUser) ||
                 (CRON_SECRET !== "" && req.headers.get("x-cron-secret") === CRON_SECRET);
  if (!cronOk) return new Response("forbidden", { status: 403, headers: CORS });

  // Run the detection SQL.
  let report: any = {};
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/costing_watchdog_report`, {
      method: "POST",
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        "content-type": "application/json",
      },
      body: "{}",
    });
    if (!r.ok) return json({ error: `report rpc ${r.status}: ${await r.text()}` }, 500);
    report = await r.json();
  } catch (e) {
    return json({ error: String(e) }, 500);
  }

  const missing = (report?.missing_cogs ?? []) as any[];
  const zeroDos = (report?.zero_cost_dos ?? []) as any[];
  const unbal = (report?.unbalanced ?? []) as any[];

  // Group every issue by org.
  const byOrg = new Map<string, { missing: any[]; zeroDos: any[]; unbal: any[] }>();
  const bucket = (org: string) => {
    if (!byOrg.has(org)) byOrg.set(org, { missing: [], zeroDos: [], unbal: [] });
    return byOrg.get(org)!;
  };
  for (const m of missing) bucket(String(m.org_id)).missing.push(m);
  for (const z of zeroDos) bucket(String(z.org_id)).zeroDos.push(z);
  for (const u of unbal) bucket(String(u.org_id)).unbal.push(u);

  if (byOrg.size === 0) {
    return json({ clean: true, orgs_with_issues: 0, sent: 0 });
  }

  // Org names for readable subjects.
  const orgIds = [...byOrg.keys()];
  const orgRows = await rest(`organizations?id=in.(${orgIds.map(enc).join(",")})&select=id,name`);
  const orgName = new Map(orgRows.map((o) => [String(o.id), String(o.name ?? o.id)]));

  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: { username: GMAIL_USER, password: GMAIL_PASS },
    },
  });

  let sent = 0;
  const unrouted: string[] = [];
  try {
    for (const [org, iss] of byOrg) {
      const em = (await rest(
        `app_config?key=eq.org.attendance_summary_emails&org_id=eq.${enc(org)}&select=value&limit=1`,
      ))[0];
      const emails = String(em?.value ?? "")
        .split(/[,;\s]+/).map((s) => s.trim()).filter((s) => s.includes("@"));
      if (!emails.length) { unrouted.push(org); continue; }

      const name = orgName.get(org) ?? org;
      const th = (t: string) =>
        `<th style="text-align:left;padding:6px 10px;background:#f1f5f9;border-bottom:1px solid #e2e8f0;font-size:12px">${t}</th>`;
      const td = (t: unknown, right = false) =>
        `<td style="padding:6px 10px;border-bottom:1px solid #f1f5f9;font-size:13px;${right ? "text-align:right" : ""}">${H(t)}</td>`;

      let html = `<div style="font-family:Segoe UI,Arial,sans-serif;max-width:680px">
        <h2 style="color:#b91c1c;margin:0 0 4px">Costing watchdog — action needed</h2>
        <div style="color:#64748b;font-size:13px;margin-bottom:16px">${H(name)} — nightly ledger sanity check</div>`;

      if (iss.missing.length) {
        html += `<h3 style="margin:16px 0 6px;font-size:14px">Invoices posted with NO cost of goods (${iss.missing.length})</h3>
          <div style="color:#64748b;font-size:12px;margin-bottom:6px">These are locked and carry revenue but booked no COGS — profit is overstated until fixed.</div>
          <table style="border-collapse:collapse;width:100%">
          <tr>${th("Invoice")}${th("Date")}${th("Amount (Rs.)")}</tr>` +
          iss.missing.map((m) => `<tr>${td(m.invoice)}${td(m.date)}${td(money(m.total), true)}</tr>`).join("") +
          `</table>`;
      }
      if (iss.zeroDos.length) {
        html += `<h3 style="margin:16px 0 6px;font-size:14px">Delivery orders posted at zero cost (${iss.zeroDos.length})</h3>
          <table style="border-collapse:collapse;width:100%">
          <tr>${th("DO")}${th("Date")}</tr>` +
          iss.zeroDos.map((z) => `<tr>${td(z.do)}${td(z.date)}</tr>`).join("") +
          `</table>`;
      }
      if (iss.unbal.length) {
        html += `<h3 style="margin:16px 0 6px;font-size:14px">Unbalanced journal entries (${iss.unbal.length})</h3>
          <table style="border-collapse:collapse;width:100%">
          <tr>${th("Entry")}${th("Debits − Credits (Rs.)")}</tr>` +
          iss.unbal.map((u) => `<tr>${td(u.entry)}${td(money(u.diff), true)}</tr>`).join("") +
          `</table>`;
      }
      html += `<div style="color:#94a3b8;font-size:11px;margin-top:18px">Automated check. It re-runs nightly and stays silent when everything is clean.</div></div>`;

      await client.send({
        from: GMAIL_USER,
        to: emails,
        subject: `⚠ Costing watchdog: ${iss.missing.length + iss.zeroDos.length + iss.unbal.length} issue(s) — ${name}`,
        html,
      });
      sent++;
    }
  } finally {
    try { await client.close(); } catch (_) { /* ignore */ }
  }

  return json({
    clean: false,
    orgs_with_issues: byOrg.size,
    sent,
    unrouted,
    counts: { missing_cogs: missing.length, zero_cost_dos: zeroDos.length, unbalanced: unbal.length },
  });
});
