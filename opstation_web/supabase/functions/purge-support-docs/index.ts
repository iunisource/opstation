// Supabase Edge Function: purge-support-docs
// Deletes voucher support documents (invoices, GRNs, JVs, DOs, returns …)
// older than each org's retention period, set per org by the Super Admin
// (Organizations → Edit → Storage). Orgs with no period keep files forever.
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
  if (claims?.sub && claims?.email) {
    const { data: me } = await admin.from("users").select("role, is_active")
      .ilike("email", String(claims.email)).eq("role", "superAdmin").limit(1);
    if (!me || me.length === 0) return json({ error: "Super Admin only" }, 403);
    try {
      const body = await req.json();
      onlyOrg = body?.org_id ?? null;
    } catch { /* no body */ }
    if (!onlyOrg) return json({ error: "org_id required" }, 400);
  }

  const totals: Record<string, { files: number; bytes: number; failed: number }> = {};
  for (let round = 0; round < 20; round++) {
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
      p_org: org, p_files: t.files, p_bytes: t.bytes,
      p_note: (onlyOrg ? "Purge now (Super Admin)" : "Daily") + (t.failed ? ` · ${t.failed} failed` : ""),
    });
  }
  if (onlyOrg && !totals[onlyOrg]) {
    await admin.rpc("log_support_docs_purge", { p_org: onlyOrg, p_files: 0, p_bytes: 0, p_note: "Purge now — nothing due" });
  }
  return json({ ok: true, orgs: totals });
});
