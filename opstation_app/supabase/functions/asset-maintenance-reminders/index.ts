// Supabase Edge Function: asset-maintenance-reminders
// Scheduled daily (via pg_cron). For every org with the maintenance-reminder
// toggle ON, emails a digest of assets whose next maintenance is overdue or
// falls within the configured lead window. Runs under the service role and is
// not tied to a caller — so it loops all orgs itself.
//
// Deploy:  supabase functions deploy asset-maintenance-reminders --no-verify-jwt
// Secrets: reuses GMAIL_USER / GMAIL_APP_PASSWORD (already set for
//          notify-customer-edit). Optionally set CRON_SECRET to lock down who
//          may trigger it (the daily cron then sends a matching x-cron-secret).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function esc(s: string): string {
  return String(s).replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" } as Record<string, string>)[c]
  );
}

function ymd(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(
    d.getDate()
  ).padStart(2, "0")}`;
}

serve(async (req) => {
  // Optional shared-secret guard (only enforced if CRON_SECRET is set).
  const need = Deno.env.get("CRON_SECRET");
  if (need && req.headers.get("x-cron-secret") !== need) {
    return json({ error: "forbidden" }, 403);
  }

  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const admin = createClient(url, serviceKey);

    // All reminder config across orgs.
    const { data: cfgRows } = await admin
      .from("app_config")
      .select("org_id, key, value")
      .in("key", [
        "org.asset_maintenance_reminder",
        "org.asset_maintenance_reminder_days",
        "org.asset_maintenance_reminder_emails",
      ]);

    const byOrg: Record<
      string,
      { enabled: boolean; days: number; emails: string[] }
    > = {};
    for (const r of cfgRows ?? []) {
      const o = r.org_id as string;
      byOrg[o] ??= { enabled: false, days: 7, emails: [] };
      const v = (r.value as string) ?? "";
      if (r.key === "org.asset_maintenance_reminder") byOrg[o].enabled = v === "true";
      else if (r.key === "org.asset_maintenance_reminder_days")
        byOrg[o].days = parseInt(v, 10) || 7;
      else if (r.key === "org.asset_maintenance_reminder_emails")
        byOrg[o].emails = v.split(/[\s,;]+/).map((s) => s.trim()).filter(Boolean);
    }

    const gmailUser = Deno.env.get("GMAIL_USER")!;
    const gmailPass = Deno.env.get("GMAIL_APP_PASSWORD")!;

    const today = new Date();
    const todayStr = ymd(today);
    const results: Record<string, unknown> = {};
    let smtp: SMTPClient | null = null;

    for (const [orgId, c] of Object.entries(byOrg)) {
      if (!c.enabled || c.emails.length === 0) {
        results[orgId] = "skipped";
        continue;
      }

      const cutoff = new Date(today);
      cutoff.setDate(cutoff.getDate() + (c.days || 0));
      const cutoffStr = ymd(cutoff);

      const { data: assets } = await admin
        .from("assets")
        .select(
          "asset_code, name, branch_id, assigned_to, status, next_maintenance_due"
        )
        .eq("org_id", orgId)
        .eq("is_active", true)
        .not("next_maintenance_due", "is", null)
        .lte("next_maintenance_due", cutoffStr)
        .order("next_maintenance_due", { ascending: true });

      if (!assets || assets.length === 0) {
        results[orgId] = "none due";
        continue;
      }

      const [{ data: branches }, { data: custs }, { data: org }] =
        await Promise.all([
          admin.from("branches").select("id, name").eq("org_id", orgId),
          admin.from("asset_custodians").select("id, name").eq("org_id", orgId),
          admin.from("orgs").select("name").eq("id", orgId).maybeSingle(),
        ]);
      const bMap: Record<string, string> = {};
      for (const b of branches ?? []) bMap[b.id as string] = b.name as string;
      const cMap: Record<string, string> = {};
      for (const x of custs ?? []) cMap[x.id as string] = x.name as string;
      const orgName = (org?.name as string) ?? "Opstation";

      const rows = assets.map((a: Record<string, unknown>) => {
        const due = a.next_maintenance_due as string;
        return {
          code: a.asset_code as string,
          name: a.name as string,
          branch: bMap[a.branch_id as string] ?? "-",
          cust: cMap[a.assigned_to as string] ?? "Unassigned",
          due,
          overdue: due <= todayStr,
        };
      });
      const overdueCount = rows.filter((r) => r.overdue).length;

      const subject =
        `Asset maintenance due — ${rows.length} item(s)` +
        (overdueCount ? ` (${overdueCount} overdue)` : "");

      const textLines = rows.map(
        (r) =>
          `${r.overdue ? "[OVERDUE] " : ""}${r.code} - ${r.name} | ${r.branch} | ${r.cust} | due ${r.due}`
      );
      const text =
        `${orgName}\nAssets needing maintenance (overdue or within ${c.days} days):\n\n` +
        textLines.join("\n") +
        `\n\nAutomated Opstation reminder.`;

      const htmlRows = rows
        .map(
          (r) =>
            `<tr style="${r.overdue ? "background:#fee2e2;" : ""}">` +
            `<td style="padding:6px 10px;border-bottom:1px solid #e2e8f0">${esc(r.code)}</td>` +
            `<td style="padding:6px 10px;border-bottom:1px solid #e2e8f0">${esc(r.name)}</td>` +
            `<td style="padding:6px 10px;border-bottom:1px solid #e2e8f0">${esc(r.branch)}</td>` +
            `<td style="padding:6px 10px;border-bottom:1px solid #e2e8f0">${esc(r.cust)}</td>` +
            `<td style="padding:6px 10px;border-bottom:1px solid #e2e8f0">${esc(r.due)}${
              r.overdue ? ' <b style="color:#dc2626">(overdue)</b>' : ""
            }</td>` +
            `</tr>`
        )
        .join("");
      const html =
        `<p><b>${esc(orgName)}</b> — assets needing maintenance (overdue or within ${c.days} days):</p>` +
        `<table style="border-collapse:collapse;font-size:13px"><thead><tr>` +
        `<th style="text-align:left;padding:6px 10px;border-bottom:2px solid #cbd5e1">Code</th>` +
        `<th style="text-align:left;padding:6px 10px;border-bottom:2px solid #cbd5e1">Asset</th>` +
        `<th style="text-align:left;padding:6px 10px;border-bottom:2px solid #cbd5e1">Branch</th>` +
        `<th style="text-align:left;padding:6px 10px;border-bottom:2px solid #cbd5e1">Custodian</th>` +
        `<th style="text-align:left;padding:6px 10px;border-bottom:2px solid #cbd5e1">Next due</th>` +
        `</tr></thead><tbody>${htmlRows}</tbody></table>` +
        `<p style="color:#888;font-size:12px">Automated Opstation reminder.</p>`;

      if (!smtp) {
        smtp = new SMTPClient({
          connection: {
            hostname: "smtp.gmail.com",
            port: 465,
            tls: true,
            auth: { username: gmailUser, password: gmailPass },
          },
        });
      }
      await smtp.send({
        from: `Opstation <${gmailUser}>`,
        to: c.emails,
        subject,
        content: text,
        html,
      });
      results[orgId] = { sent: c.emails.length, items: rows.length, overdue: overdueCount };
    }

    if (smtp) await smtp.close();
    return json({ ok: true, results });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
