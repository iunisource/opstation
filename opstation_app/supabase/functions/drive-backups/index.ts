// Supabase Edge Function: drive-backups
// Lists and downloads the nightly backup zips in a company's Google Drive folder,
// for the Restore screen in Admin Settings. Master admins / super admins only.
// Deploy:  supabase functions deploy drive-backups --no-verify-jwt
// Secrets used (already set for daily-backup): DRIVE_CLIENT_ID, DRIVE_CLIENT_SECRET
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const MAX_BYTES = 60 * 1024 * 1024;

async function driveToken(refreshToken: string): Promise<string> {
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: Deno.env.get("DRIVE_CLIENT_ID") ?? "",
      client_secret: Deno.env.get("DRIVE_CLIENT_SECRET") ?? "",
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) throw new Error(`Google sign-in failed (${j.error ?? r.status}). Reconnect Google Drive.`);
  return j.access_token as string;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    if (!jwt) return json({ error: "unauthorized" }, 401);
    const authClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });
    const { data: { user } } = await authClient.auth.getUser();
    if (!user) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const orgId = `${body?.org_id ?? ""}`;
    if (!orgId) return json({ error: "org_id required" }, 400);
    const { data: role } = await authClient.rpc("backup_caller_role", { p_org: orgId });
    if (!["masterAdmin", "superAdmin"].includes(`${role ?? ""}`)) return json({ error: "forbidden" }, 403);

    const { data: d } = await admin.from("org_backup_drive")
      .select("refresh_token, folder_id").eq("org_id", orgId).maybeSingle();
    if (!d?.refresh_token) return json({ error: "Google Drive is not connected for this company." }, 400);
    if (!d.folder_id) return json({ ok: true, files: [] });
    const token = await driveToken(d.refresh_token);
    const H = { Authorization: `Bearer ${token}` };

    if (body.action === "list") {
      const q = `'${d.folder_id}' in parents and trashed = false and name contains '.zip'`;
      const r = await fetch(
        `https://www.googleapis.com/drive/v3/files?pageSize=100&orderBy=createdTime desc&fields=files(id,name,size,createdTime)&q=${encodeURIComponent(q)}`,
        { headers: H },
      );
      const j = await r.json().catch(() => ({}));
      if (!r.ok) return json({ error: `Drive list failed (${r.status})` }, 502);
      return json({ ok: true, files: j.files ?? [] });
    }

    if (body.action === "download") {
      const id = `${body.file_id ?? ""}`;
      if (!id) return json({ error: "file_id required" }, 400);
      const m = await fetch(`https://www.googleapis.com/drive/v3/files/${id}?fields=id,name,size,parents,trashed`, { headers: H });
      const mj = await m.json().catch(() => ({}));
      if (!m.ok || mj.trashed || !(mj.parents ?? []).includes(d.folder_id)) {
        return json({ error: "That file is not in this company's backup folder." }, 403);
      }
      if (Number(mj.size ?? 0) > MAX_BYTES) {
        return json({ error: "That backup is too large to restore from here (over 60 MB). Restore by table from an upload instead." }, 413);
      }
      const f = await fetch(`https://www.googleapis.com/drive/v3/files/${id}?alt=media`, { headers: H });
      if (!f.ok) return json({ error: `Drive download failed (${f.status})` }, 502);
      const bytes = new Uint8Array(await f.arrayBuffer());
      return json({ ok: true, name: mj.name, data: encodeBase64(bytes) });
    }
    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
