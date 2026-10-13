// Supabase Edge Function: purge-support-docs
// 1) Deletes voucher support documents (invoices, GRNs, JVs, DOs, returns …)
//    older than each org's retention period, set per org by the Super Admin
//    (Organizations → Storage). Orgs with no period keep them forever.
// 2) Deletes attendance-kiosk punch photos older than each org's kiosk period
//    (default 40 days; SQL 351) and clears the photo link on the attendance row.
// 3) Archives audit-log rows older than each org's audit period (SQL 352):
//    rows → gzip JSON file in the private 'audit-archive' bucket → rows removed.
//    A table's rows are only deleted after its file is stored successfully.
// Files are removed through the Storage API (the only way that frees space),
// then the voucher_documents rows, and each run is logged per org.
//
// Callers:
//   • daily pg_cron job (SQL 350) with the service key → all orgs
//   • Super Admin "Purge now" in the app (user JWT)   → body {org_id}
//
// Deploy:  supabase functions deploy purge-support-docs --project-ref xgptodkasmytddmdnbtb

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

function jwtPayload(token: string): Record<string, unknown> | null {
  try {
    const p = token.split(".")[1];
    if (!p) return null;
    return JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/")));
  } catch {
    return null;
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Who is calling? A user token (has sub/email) must be a Super Admin and is
  // limited to one org. Anything else the gateway let through = the daily sweep.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const claims = jwtPayload(token);
  let onlyOrg: string | null = null;
  let kindOnly: string | null = null;
  if (claims?.sub && claims?.email) {
    const { data: me } = await admin.from("users").select("role, is_active")
      .ilike("email", String(claims.email)).eq("role", "superAdmin").limit(1);
    if (!me || me.length === 0) return json({ error: "Super Admin only" }, 403);
    try {
      const body = await req.json();
      onlyOrg = body?.org_id ?? null;
      kindOnly = body?.kind ?? null; // 'docs' | 'kiosk' | 'audit' | null = all
    } catch { /* no body */ }
    if (!onlyOrg) return json({ error: "org_id required" }, 400);
  }

  const totals: Record<string, { files: number; bytes: number; failed: number }> = {};
  for (let round = 0; round < 20 && (kindOnly === null || kindOnly === "docs"); round++) {
    const { data: due, error } = await admin.rpc("support_docs_due_for_purge", { p_limit: 500, p_org: onlyOrg });
    if (error) return json({ error: error.message }, 500);
    const rows = (due ?? []) as { id: string; org_id: string; bucket: string; path: string; size_bytes: number }[];
    if (rows.length === 0) break;

    const byBucket = new Map<string, typeof rows>();
    for (const r of rows) {
      const b = r.bucket || "si-documents";
      if (!byBucket.has(b)) byBucket.set(b, []);
      byBucket.get(b)!.push(r);
    }
    const doneIds: string[] = [];
    for (const [bucket, list] of byBucket) {
      for (let i = 0; i < list.length; i += 100) {
        const chunk = list.slice(i, i + 100);
        const paths = chunk.map((r) => r.path).filter(Boolean);
        const { error: rmErr } = paths.length ? await admin.storage.from(bucket).remove(paths) : { error: null };
        for (const r of chunk) {
          const t = (totals[r.org_id] ??= { files: 0, bytes: 0, failed: 0 });
          if (rmErr) { t.failed++; continue; }
          t.files++; t.bytes += Number(r.size_bytes || 0);
          doneIds.push(r.id);
        }
      }
    }
    for (let i = 0; i < doneIds.length; i += 200) {
      await admin.from("voucher_documents").delete().in("id", doneIds.slice(i, i + 200));
    }
    if (doneIds.length === 0) break; // storage refused everything — stop, try tomorrow
    if (rows.length < 500) break;
  }

  for (const [org, t] of Object.entries(totals)) {
    await admin.rpc("log_support_docs_purge", {
      p_org: org, p_files: t.files, p_bytes: t.bytes, p_kind: "docs",
      p_note: (onlyOrg ? "Purge now (Super Admin)" : "Daily") + (t.failed ? ` · ${t.failed} failed` : ""),
    });
  }
  if (onlyOrg && kindOnly === "docs" && !totals[onlyOrg]) {
    await admin.rpc("log_support_docs_purge", { p_org: onlyOrg, p_files: 0, p_bytes: 0, p_kind: "docs", p_note: "Purge now — nothing due" });
  }

  // ── Kiosk punch photos ──────────────────────────────────────────────────
  const kiosk: Record<string, { files: number; bytes: number }> = {};
  let kioskFailed = 0;
  for (let round = 0; round < 40 && (kindOnly === null || kindOnly === "kiosk"); round++) {
    const { data: due, error } = await admin.rpc("kiosk_photos_due_for_purge", { p_limit: 500, p_org: onlyOrg });
    if (error) { console.error(error.message); break; }
    const rows = (due ?? []) as { name: string; org_id: string | null; bytes: number }[];
    if (rows.length === 0) break;
    const removed: string[] = [];
    for (let i = 0; i < rows.length; i += 100) {
      const chunk = rows.slice(i, i + 100);
      const { error: rmErr } = await admin.storage.from("kiosk-punches").remove(chunk.map((r) => r.name));
      if (rmErr) { kioskFailed += chunk.length; continue; }
      for (const r of chunk) {
        const k = r.org_id ?? "_unlinked";
        const t = (kiosk[k] ??= { files: 0, bytes: 0 });
        t.files++; t.bytes += Number(r.bytes || 0);
        removed.push(r.name);
      }
    }
    if (removed.length) await admin.rpc("kiosk_photos_mark_purged", { p_names: removed });
    if (removed.length === 0 || rows.length < 500) break;
  }
  for (const [org, t] of Object.entries(kiosk)) {
    if (org === "_unlinked") continue;
    await admin.rpc("log_support_docs_purge", {
      p_org: org, p_files: t.files, p_bytes: t.bytes, p_kind: "kiosk",
      p_note: (onlyOrg ? "Purge now (Super Admin)" : "Daily") + (kioskFailed ? ` · ${kioskFailed} failed` : ""),
    });
  }
  if (onlyOrg && kindOnly === "kiosk" && !kiosk[onlyOrg]) {
    await admin.rpc("log_support_docs_purge", { p_org: onlyOrg, p_files: 0, p_bytes: 0, p_kind: "kiosk", p_note: "Purge now — nothing due" });
  }

  // ── Audit-log archive ───────────────────────────────────────────────────
  const audit: Record<string, { rows: number; bytes: number; files: number }> = {};
  const auditErrors: string[] = [];
  if (kindOnly === null || kindOnly === "audit") {
    const { data: due, error } = await admin.rpc("audit_archive_due", { p_org: onlyOrg });
    if (error) auditErrors.push(error.message);
    for (const d of (due ?? []) as { org_id: string; table_name: string; cutoff: string; due: number }[]) {
      for (let round = 0; round < 20; round++) {
        const { data: rows, error: fe } = await admin.rpc("audit_archive_fetch", {
          p_org: d.org_id, p_table: d.table_name, p_cutoff: d.cutoff, p_limit: 5000,
        });
        if (fe) { auditErrors.push(`${d.table_name}: ${fe.message}`); break; }
        const list = (rows ?? []) as Record<string, unknown>[];
        if (list.length === 0) break;
        const text = JSON.stringify({ org_id: d.org_id, table: d.table_name, exported_at: new Date().toISOString(), rows: list });
        const gz = new Uint8Array(await new Response(
          new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer());
        const tsKey = (r: Record<string, unknown>) =>
          String(r["created_at"] ?? r["performed_at"] ?? r["changed_at"] ?? r["logged_at"] ?? "");
        const from = tsKey(list[0]) || null, to = tsKey(list[list.length - 1]) || null;
        const path = `${d.org_id}/${d.table_name}/${(from ?? "").slice(0, 10)}_to_${(to ?? "").slice(0, 10)}_${Date.now()}.json.gz`;
        const { error: upErr } = await admin.storage.from("audit-archive")
          .upload(path, gz, { contentType: "application/gzip", upsert: false });
        if (upErr) { auditErrors.push(`${d.table_name}: upload ${upErr.message}`); break; } // keep rows
        const { error: ce } = await admin.rpc("audit_archive_commit", {
          p_org: d.org_id, p_table: d.table_name, p_path: path,
          p_ids: list.map((r) => String(r["id"])), p_bytes: gz.length, p_from: from, p_to: to,
        });
        if (ce) { auditErrors.push(`${d.table_name}: ${ce.message}`); break; }
        const t = (audit[d.org_id] ??= { rows: 0, bytes: 0, files: 0 });
        t.rows += list.length; t.bytes += gz.length; t.files++;
        if (list.length < 5000) break;
      }
    }
    for (const [org, t] of Object.entries(audit)) {
      await admin.rpc("log_support_docs_purge", {
        p_org: org, p_files: t.rows, p_bytes: t.bytes, p_kind: "audit",
        p_note: `${onlyOrg ? "Archive now (Super Admin)" : "Daily"} · ${t.files} file(s)` +
          (auditErrors.length ? ` · ${auditErrors.length} error(s)` : ""),
      });
    }
    if (onlyOrg && kindOnly === "audit" && !audit[onlyOrg]) {
      await admin.rpc("log_support_docs_purge", {
        p_org: onlyOrg, p_files: 0, p_bytes: 0, p_kind: "audit",
        p_note: auditErrors.length ? `Failed: ${auditErrors[0]}`.slice(0, 300) : "Archive now — nothing due",
      });
    }
  }
  return json({ ok: true, orgs: totals, kiosk, audit, auditErrors });
});
