// Supabase Edge Function: drive-oauth
// Connects / disconnects an organisation's Google Drive for daily backups.
//
//   POST {action:"start", org_id}       master admin -> { url } (Google sign-in page)
//   GET  ?code=…&state=…                 Google sends the user back here; we save
//                                        the Drive access and return to the app
//   POST {action:"disconnect", org_id}  master admin -> revokes access, removes it
//
// Only "drive.file" access is requested: Opstation can see and manage ONLY the
// files it creates (the backup folder and zips) — nothing else in the Drive.
//
// Deploy:  supabase functions deploy drive-oauth --no-verify-jwt
// Secrets: DRIVE_CLIENT_ID, DRIVE_CLIENT_SECRET
//          APP_URL (optional, default https://opstation-f06c7.web.app)
// Requires SQL 457.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const SCOPES = "https://www.googleapis.com/auth/drive.file openid email";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const clientId = Deno.env.get("DRIVE_CLIENT_ID") ?? "";
  const clientSecret = Deno.env.get("DRIVE_CLIENT_SECRET") ?? "";
  const appUrl = (Deno.env.get("APP_URL") ?? "https://opstation-f06c7.web.app").replace(/\/+$/, "");
  const redirectUri = `${url}/functions/v1/drive-oauth`;
  const admin = createClient(url, serviceKey);

  const backToApp = (result: string, msg = "") =>
    Response.redirect(
      `${appUrl}/#/erp/admin-settings?drive=${result}${msg ? `&msg=${encodeURIComponent(msg)}` : ""}`,
      302,
    );

  // ── Google sends the user back here ──────────────────────────────────────
  if (req.method === "GET") {
    const q = new URL(req.url).searchParams;
    const code = q.get("code");
    const state = q.get("state");
    if (q.get("error")) return backToApp("cancelled");
    if (!code || !state) return backToApp("error", "Missing sign-in details");

    const { data: st } = await admin.from("drive_oauth_states").select("*").eq("state", state).maybeSingle();
    await admin.from("drive_oauth_states").delete().eq("state", state);
    if (!st || Date.now() - new Date(st.created_at).getTime() > 15 * 60 * 1000) {
      return backToApp("error", "The connect request expired. Please try again.");
    }

    // Code -> tokens
    const tok = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code, client_id: clientId, client_secret: clientSecret,
        redirect_uri: redirectUri, grant_type: "authorization_code",
      }),
    }).then((r) => r.json()).catch(() => ({}));
    if (!tok.refresh_token || !tok.access_token) {
      return backToApp("error", "Google did not grant access. Please try again.");
    }

    // Which Google account
    let email = "";
    try {
      const u = await fetch("https://openidconnect.googleapis.com/v1/userinfo", {
        headers: { Authorization: `Bearer ${tok.access_token}` },
      }).then((r) => r.json());
      email = u.email ?? "";
    } catch (_) { /* optional */ }

    // Org name -> folder name
    let orgName = "";
    try {
      const { data: o } = await admin.from("orgs").select("name").eq("id", st.org_id).maybeSingle();
      orgName = o?.name ?? "";
    } catch (_) { /* optional */ }
    const folderName = `Opstation Backups – ${orgName || st.org_id}`;

    // Create the backup folder
    const f = await fetch("https://www.googleapis.com/drive/v3/files?fields=id,name", {
      method: "POST",
      headers: { Authorization: `Bearer ${tok.access_token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ name: folderName, mimeType: "application/vnd.google-apps.folder" }),
    }).then((r) => r.json()).catch(() => ({}));
    if (!f.id) return backToApp("error", "Could not create the backup folder in Google Drive.");

    // A previous connection's access is replaced (and revoked).
    const { data: old } = await admin.from("org_backup_drive").select("refresh_token").eq("org_id", st.org_id).maybeSingle();
    const { error } = await admin.from("org_backup_drive").upsert({
      org_id: st.org_id,
      google_email: email,
      refresh_token: tok.refresh_token,
      folder_id: f.id,
      folder_name: folderName,
      connected_by: st.user_id,
      connected_by_name: st.user_name,
      connected_at: new Date().toISOString(),
      status: "ok",
      last_error: null,
      updated_at: new Date().toISOString(),
    });
    if (error) return backToApp("error", "Could not save the connection.");
    if (old?.refresh_token && old.refresh_token !== tok.refresh_token) {
      fetch(`https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(old.refresh_token)}`, { method: "POST" })
        .catch(() => {});
    }
    // Drive becomes a backup target.
    try {
      const { data: t } = await admin.from("app_config").select("value")
        .eq("org_id", st.org_id).eq("key", "org.backup_targets").is("branch_id", null).maybeSingle();
      const set = new Set(`${t?.value ?? "email"}`.split(",").map((s) => s.trim()).filter(Boolean));
      set.add("drive");
      await admin.from("app_config").upsert(
        { org_id: st.org_id, key: "org.backup_targets", value: [...set].join(",") },
        { onConflict: "key,org_id,branch_id" },
      );
    } catch (_) { /* the card can still tick it */ }
    return backToApp("connected");
  }

  // ── Calls from the settings card (signed-in master admin) ────────────────
  try {
    if (!clientId || !clientSecret) {
      return json({ error: "Google Drive is not set up on the server yet (DRIVE_CLIENT_ID / DRIVE_CLIENT_SECRET)." }, 500);
    }
    const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    if (!jwt) return json({ error: "unauthorized" }, 401);
    const body = await req.json().catch(() => ({}));
    const orgId = `${body.org_id ?? ""}`;
    if (!orgId) return json({ error: "org_id required" }, 400);

    const userClient = createClient(url, anonKey, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
    const { data: role } = await userClient.rpc("backup_caller_role", { p_org: orgId });
    if (role !== "masterAdmin" && role !== "superAdmin") {
      return json({ error: "Only master admins can connect or disconnect Google Drive." }, 403);
    }

    if (body.action === "start") {
      const { data: { user } } = await userClient.auth.getUser();
      let userId: string | null = null, userName: string | null = null;
      if (user?.email) {
        const { data: u } = await admin.from("users").select("id, name, org_id")
          .ilike("email", user.email).order("org_id").limit(5);
        const mine = (u ?? []).find((x) => x.org_id === orgId) ?? (u ?? [])[0];
        userId = mine?.id ?? null; userName = mine?.name ?? null;
      }
      const state = crypto.randomUUID() + crypto.randomUUID().replace(/-/g, "");
      await admin.from("drive_oauth_states").delete().lt("created_at", new Date(Date.now() - 3600_000).toISOString());
      const { error } = await admin.from("drive_oauth_states").insert({ state, org_id: orgId, user_id: userId, user_name: userName });
      if (error) return json({ error: "Could not start (run SQL 457 first)." }, 500);
      const p = new URLSearchParams({
        client_id: clientId, redirect_uri: redirectUri, response_type: "code",
        scope: SCOPES, access_type: "offline", prompt: "consent", include_granted_scopes: "true", state,
      });
      return json({ url: `https://accounts.google.com/o/oauth2/v2/auth?${p}` });
    }

    if (body.action === "disconnect") {
      const { data: row } = await admin.from("org_backup_drive").select("refresh_token").eq("org_id", orgId).maybeSingle();
      if (row?.refresh_token) {
        await fetch(`https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(row.refresh_token)}`, { method: "POST" })
          .catch(() => {});
      }
      await admin.from("org_backup_drive").delete().eq("org_id", orgId);
      // Stop sending to Drive (email stays as it was).
      const { data: t } = await admin.from("app_config").select("value")
        .eq("org_id", orgId).eq("key", "org.backup_targets").is("branch_id", null).maybeSingle();
      const set = new Set(`${t?.value ?? "email"}`.split(",").map((s) => s.trim()).filter((s) => s && s !== "drive"));
      await admin.from("app_config").upsert(
        { org_id: orgId, key: "org.backup_targets", value: [...set].join(",") || "email" },
        { onConflict: "key,org_id,branch_id" },
      );
      return json({ ok: true });
    }

    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
