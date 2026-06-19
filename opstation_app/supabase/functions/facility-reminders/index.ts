// Daily facility-upkeep reminder digest. Scheduled via pg_cron (service role).
// For each org that turned the reminder on (app_config 'org.facility_reminder'),
// emails the configured recipients a digest of overdue + due-today facility
// tasks, grouped by branch. Mirrors the asset-maintenance reminder.

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

const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
function fmtDate(d?: string | null): string {
  if (!d) return "—";
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d);
  if (!m) return d;
  return `${parseInt(m[3], 10)} ${MONTHS[parseInt(m[2], 10) - 1]} ${m[1]}`;
}
const title = (s?: string | null) =>
  !s ? "" : s.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());

Deno.serve(async (req) => {
  if (CRON_SECRET && req.headers.get("x-cron-secret") !== CRON_SECRET) {
    return new Response("forbidden", { status: 403 });
  }

  const today = new Date().toISOString().slice(0, 10);

  const toggles = await rest(
    `app_config?key=eq.org.facility_reminder&select=org_id,value`,
  );
  const orgs = toggles
    .filter((t) => ["true", "1", "on", "yes"].includes(String(t.value).toLowerCase()))
    .map((t) => t.org_id as string);

  if (!orgs.length) {
    return new Response(JSON.stringify({ orgs: 0, sent: 0 }), {
      headers: { "content-type": "application/json" },
    });
  }

  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: { username: GMAIL_USER, password: GMAIL_PASS },
    },
  });

  let sent = 0;
  try {
    for (const org of orgs) {
      const [em] = await rest(
        `app_config?key=eq.org.facility_reminder_emails&org_id=eq.${enc(org)}&select=value&limit=1`,
      );
      const emails = String(em?.value ?? "")
        .split(",").map((s) => s.trim()).filter(Boolean);
      if (!emails.length) continue;

      const tasks = await rest(
        `facility_tasks?org_id=eq.${enc(org)}&status=eq.open&due_date=lte.${today}` +
          `&order=due_date&select=title,category,due_date,branch_id,area_id`,
      );
      if (!tasks.length) continue;

      const branches = await rest(`branches?org_id=eq.${enc(org)}&select=id,name`);
      const areas = await rest(`facility_areas?org_id=eq.${enc(org)}&select=id,name`);
      const bName: Record<string, string> = {};
      for (const b of branches) bName[b.id] = b.name;
      const aName: Record<string, string> = {};
      for (const a of areas) aName[a.id] = a.name;

      // group by branch
      const groups: Record<string, any[]> = {};
      for (const t of tasks) {
        const key = bName[t.branch_id] ?? "—";
        (groups[key] ??= []).push(t);
      }

      let rowsHtml = "";
      for (const [branch, list] of Object.entries(groups)) {
        rowsHtml += `<tr><td colspan="3" style="padding:10px 8px 4px;font-weight:700">${H(branch)}</td></tr>`;
        for (const t of list) {
          const overdue = String(t.due_date) < today;
          rowsHtml +=
            `<tr>` +
            `<td style="padding:6px 8px;border-top:1px solid #eee">${H(t.title)}` +
            (t.area_id && aName[t.area_id] ? ` <span style="color:#888">· ${H(aName[t.area_id])}</span>` : "") +
            `</td>` +
            `<td style="padding:6px 8px;border-top:1px solid #eee;color:#888">${H(title(t.category))}</td>` +
            `<td style="padding:6px 8px;border-top:1px solid #eee;text-align:right;color:${overdue ? "#c0392b" : "#555"}">` +
            `${fmtDate(t.due_date)}${overdue ? " (overdue)" : ""}</td>` +
            `</tr>`;
        }
      }

      const html =
        `<div style="font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:640px">` +
        `<h2 style="margin:0 0 4px">Facility upkeep — ${tasks.length} task(s) due</h2>` +
        `<p style="color:#666;margin:0 0 12px">Open tasks due today or overdue.</p>` +
        `<table style="width:100%;border-collapse:collapse;font-size:14px">` +
        `<thead><tr style="text-align:left;color:#888;font-size:12px">` +
        `<th style="padding:6px 8px">Task</th><th style="padding:6px 8px">Type</th>` +
        `<th style="padding:6px 8px;text-align:right">Due</th></tr></thead>` +
        `<tbody>${rowsHtml}</tbody></table>` +
        `<p style="color:#999;font-size:12px;margin-top:14px">Opstation · Facility</p></div>`;

      const text = tasks
        .map((t) => `- ${t.title} [${title(t.category)}] due ${fmtDate(t.due_date)}` +
          (String(t.due_date) < today ? " (overdue)" : ""))
        .join("\n");

      await client.send({
        from: GMAIL_USER,
        to: emails,
        subject: `Facility upkeep — ${tasks.length} task(s) due`,
        content: text,
        html,
      });
      sent++;
    }
  } finally {
    await client.close();
  }

  return new Response(JSON.stringify({ orgs: orgs.length, sent }), {
    headers: { "content-type": "application/json" },
  });
});
