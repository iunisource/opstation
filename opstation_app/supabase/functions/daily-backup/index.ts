// Supabase Edge Function: daily-backup
// Per-org nightly backup. Exports every org-scoped table to CSV, zips them,
// and emails the zip to the org's configured backup address(es).
//
// Modes:
//   • CRON   — header x-cron-secret == CRON_SECRET: backs up EVERY org that has
//              org.backup_emails set (and org.backup_enabled != 'false').
//   • MANUAL — a valid admin/masterAdmin JWT: backs up just the caller's org
//              (powers a "Back up now" button in admin settings).
//
// Deploy:  supabase functions deploy daily-backup --no-verify-jwt
// Secrets: GMAIL_USER, GMAIL_APP_PASSWORD, CRON_SECRET   (already set)
//          SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY (auto-injected)
// Requires SQL: public.list_org_backup_tables()

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";
import JSZip from "https://esm.sh/jszip@3.10.1";
import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-cron-secret",
};
function json(o: unknown, s = 200): Response {
  return new Response(JSON.stringify(o), {
    status: s,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

const MAX_EMAIL_BYTES = 24 * 1024 * 1024; // Gmail-safe ceiling (~24 MB)

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const admin = createClient(url, serviceKey);

    // ---- Mode: cron (all orgs) vs manual (one org) -------------------------
    const cronSecret = Deno.env.get("CRON_SECRET") ?? "";
    const headerSecret = req.headers.get("x-cron-secret") ?? "";
    let orgFilter: string | null = null; // null = all orgs

    if (!cronSecret || headerSecret !== cronSecret) {
      const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
      if (!jwt) return json({ error: "unauthorized" }, 401);
      const authClient = createClient(url, anonKey, {
        global: { headers: { Authorization: `Bearer ${jwt}` } },
      });
      const { data: { user } } = await authClient.auth.getUser();
      if (!user?.email) return json({ error: "unauthorized" }, 401);
      const { data: pu } = await admin
        .from("users").select("org_id, role").eq("email", user.email).maybeSingle();
      if (!pu?.org_id) return json({ error: "no org for caller" }, 400);
      if (!["admin", "masterAdmin", "superAdmin"].includes(`${pu.role ?? ""}`)) {
        return json({ error: "forbidden" }, 403);
      }
      orgFilter = pu.org_id as string;
    }

    // ---- Per-org backup config (app_config) --------------------------------
    let cfgQ = admin.from("app_config").select("org_id, key, value")
      .in("key", ["org.backup_emails", "org.backup_enabled"]);
    if (orgFilter) cfgQ = cfgQ.eq("org_id", orgFilter);
    const { data: cfgRows, error: cfgErr } = await cfgQ;
    if (cfgErr) return json({ error: `config read failed: ${cfgErr.message}` }, 500);

    const byOrg: Record<string, { emails: string; enabled: boolean }> = {};
    for (const r of cfgRows ?? []) {
      const o = r.org_id as string;
      byOrg[o] = byOrg[o] ?? { emails: "", enabled: true };
      if (r.key === "org.backup_emails") byOrg[o].emails = (r.value as string) ?? "";
      if (r.key === "org.backup_enabled") byOrg[o].enabled = `${r.value}`.toLowerCase() !== "false";
    }

    // org names (for filenames); ignore if table differs
    const orgName: Record<string, string> = {};
    try {
      const { data: orgs } = await admin.from("organizations").select("id, name");
      for (const o of orgs ?? []) orgName[o.id as string] = (o.name as string) ?? (o.id as string);
    } catch (_) { /* fallback to id */ }

    // org-scoped tables
    const { data: tableList, error: tlErr } = await admin.rpc("list_org_backup_tables");
    if (tlErr) return json({ error: `table list failed: ${tlErr.message}` }, 500);
    const tables: string[] = (tableList as string[]) ?? [];

    if (Object.keys(byOrg).length === 0) {
      return json({
        ok: true,
        mode: orgFilter ? "manual" : "cron",
        count: 0,
        note: "no orgs have a backup email configured (set app_config org.backup_emails)",
      });
    }

    const gmailUser = Deno.env.get("GMAIL_USER")!;
    const gmailPass = Deno.env.get("GMAIL_APP_PASSWORD")!;
    const smtp = new SMTPClient({
      connection: { hostname: "smtp.gmail.com", port: 465, tls: true, auth: { username: gmailUser, password: gmailPass } },
    });

    const today = new Date().toISOString().slice(0, 10);
    const results: Record<string, unknown>[] = [];

    for (const [orgId, conf] of Object.entries(byOrg)) {
      const recipients = conf.emails.split(/[,;\s]+/).map((s) => s.trim()).filter(Boolean);
      if (!conf.enabled || recipients.length === 0) {
        results.push({ org: orgId, status: "skipped", recipients: recipients.length });
        continue;
      }

      const zip = new JSZip();
      const folder = zip.folder(`opstation-backup-${today}`)!;
      let tableCount = 0;

      for (const t of tables) {
        try {
          const resp = await fetch(
            `${url}/rest/v1/${t}?org_id=eq.${encodeURIComponent(orgId)}&select=*`,
            { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, Accept: "text/csv" } },
          );
          const csv = await resp.text();
          if (!resp.ok) { folder.file(`${t}.error.txt`, csv); continue; }
          folder.file(`${t}.csv`, csv ?? "");
          tableCount++;
        } catch (e) {
          folder.file(`${t}.error.txt`, String(e));
        }
      }

      folder.file(
        "_manifest.txt",
        `Opstation backup\nOrganization: ${orgName[orgId] ?? orgId} (${orgId})\n` +
          `Date: ${today}\nTables exported: ${tableCount}\nGenerated (UTC): ${new Date().toISOString()}\n`,
      );

      const bytes = await zip.generateAsync({
        type: "uint8array", compression: "DEFLATE", compressionOptions: { level: 6 },
      });
      const safeName = (orgName[orgId] ?? "org").replace(/[^a-zA-Z0-9_-]+/g, "-");
      const fileName = `opstation-backup-${safeName}-${today}.zip`;

      if (bytes.length > MAX_EMAIL_BYTES) {
        await smtp.send({
          from: `Opstation Backups <${gmailUser}>`,
          to: recipients,
          subject: `Opstation backup ${today} — too large to email`,
          content:
            `Today's backup for ${orgName[orgId] ?? orgId} is ` +
            `${(bytes.length / 1048576).toFixed(1)} MB, above the email limit. ` +
            `Please contact your administrator to retrieve it another way.`,
        });
        results.push({ org: orgId, status: "too_large", tables: tableCount, mb: +(bytes.length / 1048576).toFixed(1) });
        continue;
      }

      await smtp.send({
        from: `Opstation Backups <${gmailUser}>`,
        to: recipients,
        subject: `Opstation backup — ${orgName[orgId] ?? orgId} — ${today}`,
        content:
          `Attached is the daily data backup for ${orgName[orgId] ?? orgId} (${today}).\n\n` +
          `${tableCount} tables exported as CSV inside the zip.\n` +
          `This is an automated message from Opstation.`,
        attachments: [{
          filename: fileName,
          content: encodeBase64(bytes),
          encoding: "base64",
          contentType: "application/zip",
        }],
      });
      results.push({ org: orgId, status: "sent", recipients: recipients.length, tables: tableCount, mb: +(bytes.length / 1048576).toFixed(2) });
    }

    try { await smtp.close(); } catch (_) { /* nothing was sent / not connected */ }
    return json({ ok: true, mode: orgFilter ? "manual" : "cron", count: results.length, results });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
