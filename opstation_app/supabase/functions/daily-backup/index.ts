// Supabase Edge Function: daily-backup
// Per-org nightly backup. Exports every org-scoped table to CSV, zips them,
// and sends the zip to the org's chosen places (org.backup_targets):
//   • email        — the org's backup address(es)  (up to ~24 MB)
//   • drive        — the org's connected Google Drive folder (any size, SQL 457
//                    + drive-oauth); older files are deleted after
//                    org.backup_drive_keep_days days (0 = keep all).
// If the Drive upload fails, the zip is emailed instead when it fits, and the
// org's master admins are told.
//
// Modes:
//   • CRON   — header x-cron-secret == CRON_SECRET: backs up EVERY org that has
//              org.backup_emails set (and org.backup_enabled != 'false').
//   • MANUAL — a valid admin/masterAdmin JWT: backs up just the caller's org
//              (powers a "Back up now" button in admin settings).
//
// Deploy:  supabase functions deploy daily-backup --no-verify-jwt
// Secrets: GMAIL_USER, GMAIL_APP_PASSWORD, CRON_SECRET   (already set)
//          GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET             (for Google Drive)
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

type DriveRow = { org_id: string; refresh_token: string; folder_id: string | null; folder_name: string | null };

class DriveAuthError extends Error {}

async function driveToken(refreshToken: string): Promise<string> {
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: Deno.env.get("GOOGLE_CLIENT_ID") ?? "",
      client_secret: Deno.env.get("GOOGLE_CLIENT_SECRET") ?? "",
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) {
    if (j.error === "invalid_grant") throw new DriveAuthError("access removed");
    throw new Error(`token ${r.status} ${j.error ?? ""}`);
  }
  return j.access_token as string;
}

/** The backup folder, made again if someone deleted or trashed it. */
async function driveFolder(token: string, d: DriveRow): Promise<string> {
  if (d.folder_id) {
    const r = await fetch(`https://www.googleapis.com/drive/v3/files/${d.folder_id}?fields=id,trashed`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (r.ok) {
      const j = await r.json();
      if (!j.trashed) return d.folder_id;
    }
  }
  const r = await fetch("https://www.googleapis.com/drive/v3/files?fields=id", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ name: d.folder_name ?? "Opstation Backups", mimeType: "application/vnd.google-apps.folder" }),
  });
  const j = await r.json().catch(() => ({}));
  if (!j.id) throw new Error(`folder ${r.status}`);
  return j.id as string;
}

async function driveUpload(token: string, folderId: string, name: string, bytes: Uint8Array) {
  const start = await fetch(
    "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json; charset=UTF-8",
        "X-Upload-Content-Type": "application/zip",
        "X-Upload-Content-Length": `${bytes.length}`,
      },
      body: JSON.stringify({ name, parents: [folderId], mimeType: "application/zip" }),
    },
  );
  const loc = start.headers.get("Location");
  if (!start.ok || !loc) throw new Error(`upload start ${start.status}`);
  const put = await fetch(loc, { method: "PUT", headers: { "Content-Type": "application/zip" }, body: bytes });
  const j = await put.json().catch(() => ({}));
  if (!put.ok || !j.id) throw new Error(`upload ${put.status}`);
  return j as { id: string; webViewLink?: string };
}

/** Deletes backup files in the folder older than [days] (0 = keep all). */
async function driveCleanup(token: string, folderId: string, days: number) {
  if (!days || days <= 0) return 0;
  const before = new Date(Date.now() - days * 86400_000).toISOString();
  const q = `'${folderId}' in parents and trashed = false and createdTime < '${before}'`;
  const r = await fetch(
    `https://www.googleapis.com/drive/v3/files?pageSize=1000&fields=files(id)&q=${encodeURIComponent(q)}`,
    { headers: { Authorization: `Bearer ${token}` } },
  );
  const j = await r.json().catch(() => ({}));
  let n = 0;
  for (const f of (j.files ?? []) as { id: string }[]) {
    const d = await fetch(`https://www.googleapis.com/drive/v3/files/${f.id}`, {
      method: "DELETE", headers: { Authorization: `Bearer ${token}` },
    });
    if (d.ok) n++;
  }
  return n;
}

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
      // The company open on screen (body.org_id), checked against the caller.
      const body = await req.json().catch(() => ({}));
      const wanted = `${body?.org_id ?? ""}`;
      if (wanted) {
        const { data: role } = await authClient.rpc("backup_caller_role", { p_org: wanted });
        if (!["admin", "masterAdmin", "superAdmin"].includes(`${role ?? ""}`)) {
          return json({ error: "forbidden" }, 403);
        }
        orgFilter = wanted;
      } else {
        const { data: pu } = await admin
          .from("users").select("org_id, role").eq("email", user.email).limit(1).maybeSingle();
        if (!pu?.org_id) return json({ error: "no org for caller" }, 400);
        if (!["admin", "masterAdmin", "superAdmin"].includes(`${pu.role ?? ""}`)) {
          return json({ error: "forbidden" }, 403);
        }
        orgFilter = pu.org_id as string;
      }
    }

    // ---- Per-org backup config (app_config) --------------------------------
    let cfgQ = admin.from("app_config").select("org_id, key, value")
      .in("key", ["org.backup_emails", "org.backup_enabled", "org.backup_targets", "org.backup_drive_keep_days"]);
    if (orgFilter) cfgQ = cfgQ.eq("org_id", orgFilter);
    const { data: cfgRows, error: cfgErr } = await cfgQ;
    if (cfgErr) return json({ error: `config read failed: ${cfgErr.message}` }, 500);

    type Conf = { emails: string; enabled: boolean; targets: string; keepDays: number };
    const byOrg: Record<string, Conf> = {};
    const blank = (): Conf => ({ emails: "", enabled: true, targets: "email", keepDays: 30 });
    for (const r of cfgRows ?? []) {
      const o = r.org_id as string;
      byOrg[o] = byOrg[o] ?? blank();
      if (r.key === "org.backup_emails") byOrg[o].emails = (r.value as string) ?? "";
      if (r.key === "org.backup_enabled") byOrg[o].enabled = `${r.value}`.toLowerCase() !== "false";
      if (r.key === "org.backup_targets") byOrg[o].targets = `${r.value ?? ""}` || "email";
      if (r.key === "org.backup_drive_keep_days") {
        const n = parseInt(`${r.value}`, 10);
        byOrg[o].keepDays = Number.isFinite(n) ? n : 30;
      }
    }

    // Connected Google Drives (SQL 457). Missing table = no Drive yet.
    const drives: Record<string, DriveRow> = {};
    {
      let dq = admin.from("org_backup_drive").select("org_id, refresh_token, folder_id, folder_name");
      if (orgFilter) dq = dq.eq("org_id", orgFilter);
      const { data } = await dq;
      for (const d of (data ?? []) as DriveRow[]) {
        drives[d.org_id] = d;
        byOrg[d.org_id] = byOrg[d.org_id] ?? blank();
      }
    }

    // Master admins of an org (told when the Drive upload fails).
    async function masterAdminEmails(orgId: string): Promise<string[]> {
      const { data } = await admin.from("users").select("email")
        .eq("org_id", orgId).eq("role", "masterAdmin");
      return (data ?? []).map((u: { email: string | null }) => `${u.email ?? ""}`.trim()).filter(Boolean);
    }

    // org names (for filenames); ignore if table differs
    // org names (for subject/body/filenames). The org table name + key column
    // vary, so scan likely candidates and map every key value -> name.
    const orgName: Record<string, string> = {};
    {
      const keyCols = ["id", "org_id", "slug", "code", "uuid"];
      const nameCols = ["name", "org_name", "title", "display_name", "label", "company_name"];
      for (const table of ["organizations", "orgs", "organization", "companies"]) {
        try {
          const { data, error } = await admin.from(table).select("*");
          if (error || !data) continue;
          for (const row of data as Record<string, unknown>[]) {
            let nm = "";
            for (const nc of nameCols) { if (row[nc]) { nm = `${row[nc]}`; break; } }
            if (!nm) continue;
            for (const kc of keyCols) { if (row[kc] != null) orgName[`${row[kc]}`] = nm; }
          }
          if (Object.keys(orgName).length) break; // usable table found
        } catch (_) { /* try next candidate */ }
      }
    }

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
      const targets = new Set(conf.targets.split(",").map((s) => s.trim()));
      const wantEmail = targets.has("email") && recipients.length > 0;
      const drive = targets.has("drive") ? drives[orgId] : undefined;
      if (!conf.enabled || (!wantEmail && !drive)) {
        results.push({ org: orgId, status: "skipped", recipients: recipients.length });
        continue;
      }

      const zip = new JSZip();
      const label = orgName[orgId] ? `${orgName[orgId]} (${orgId})` : orgId;
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
        `Opstation backup\nOrganization: ${label}\n` +
          `Date: ${today}\nTables exported: ${tableCount}\nGenerated (UTC): ${new Date().toISOString()}\n`,
      );

      const bytes = await zip.generateAsync({
        type: "uint8array", compression: "DEFLATE", compressionOptions: { level: 6 },
      });
      const safeName = (orgName[orgId] ?? "org").replace(/[^a-zA-Z0-9_-]+/g, "-");
      const fileName = `opstation-backup-${safeName}-${today}.zip`;

      // ── Google Drive ──────────────────────────────────────────────────────
      let driveStatus: string | null = null;
      if (drive) {
        try {
          const token = await driveToken(drive.refresh_token);
          const folderId = await driveFolder(token, drive);
          const file = await driveUpload(token, folderId, fileName, bytes);
          let removed = 0;
          try { removed = await driveCleanup(token, folderId, conf.keepDays); } catch (_) { /* next night */ }
          await admin.from("org_backup_drive").update({
            folder_id: folderId, status: "ok", last_error: null,
            last_backup_at: new Date().toISOString(), last_backup_bytes: bytes.length,
            last_backup_tables: tableCount, last_file_link: file.webViewLink ?? null,
            updated_at: new Date().toISOString(),
          }).eq("org_id", orgId);
          driveStatus = "ok";
          if (removed > 0) driveStatus = `ok (${removed} old removed)`;
        } catch (e) {
          const reconnect = e instanceof DriveAuthError;
          driveStatus = reconnect ? "needs_reconnect" : "failed";
          const why = String((e as Error)?.message ?? e).slice(0, 300);
          await admin.from("org_backup_drive").update({
            status: reconnect ? "needs_reconnect" : "error",
            last_error: why,
            updated_at: new Date().toISOString(),
          }).eq("org_id", orgId);
          try {
            const to = await masterAdminEmails(orgId);
            if (to.length) {
              await smtp.send({
                from: `Opstation Backups <${gmailUser}>`,
                to,
                subject: `Opstation backup - ${label} - ${today} - Google Drive ${reconnect ? "needs reconnecting" : "upload failed"}`,
                content: reconnect
                  ? `Google no longer allows Opstation to save backups to the connected Drive for ${label}.\n` +
                    `Open Admin Settings > Daily data backup and click Reconnect.`
                  : `Today's backup for ${label} could not be saved to Google Drive (${why}). It will be tried again tonight.`,
              });
            }
          } catch (_) { /* best effort */ }
        }
      }

      // Email: when chosen — or as the fallback when Drive failed and it fits.
      const driveFailed = driveStatus !== null && !driveStatus.startsWith("ok");
      const emailNow = wantEmail || (driveFailed && recipients.length > 0 && bytes.length <= MAX_EMAIL_BYTES);
      if (!emailNow) {
        results.push({
          org: orgId, status: driveFailed ? "drive_failed" : "drive", drive: driveStatus,
          tables: tableCount, mb: +(bytes.length / 1048576).toFixed(2),
        });
        continue;
      }

      if (bytes.length > MAX_EMAIL_BYTES) {
        await smtp.send({
          from: `Opstation Backups <${gmailUser}>`,
          to: recipients,
          subject: `Opstation backup - ${label} - ${today} - too large to email`,
          content:
            `Today's backup for ${label} is ` +
            `${(bytes.length / 1048576).toFixed(1)} MB, above the email limit. ` +
            (driveStatus?.startsWith("ok")
              ? `It was saved to the company's Google Drive backup folder.`
              : `Connect a Google Drive in Admin Settings > Daily data backup to keep backups of any size.`),
        });
        results.push({ org: orgId, status: "too_large", drive: driveStatus, tables: tableCount, mb: +(bytes.length / 1048576).toFixed(1) });
        continue;
      }

      await smtp.send({
        from: `Opstation Backups <${gmailUser}>`,
        to: recipients,
        subject: `Opstation backup - ${label} - ${today}`,
        content:
          `Attached is the daily data backup for ${label}, dated ${today}.\n\n` +
          `${tableCount} tables exported as CSV inside the zip.\n` +
          `This is an automated message from Opstation.`,
        attachments: [{
          filename: fileName,
          content: encodeBase64(bytes),
          encoding: "base64",
          contentType: "application/zip",
        }],
      });
      results.push({ org: orgId, status: "sent", drive: driveStatus, recipients: recipients.length, tables: tableCount, mb: +(bytes.length / 1048576).toFixed(2) });
    }

    try { await smtp.close(); } catch (_) { /* nothing was sent / not connected */ }
    return json({ ok: true, mode: orgFilter ? "manual" : "cron", count: results.length, results });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
