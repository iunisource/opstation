// Supabase Edge Function: send-push
// Called by the database (push_send__impl -> pg_net) with x-webhook-secret.
//  1) Web Push to the browser subscriptions of the org / the given users (unchanged).
//  2) NEW: Firebase push to the phone tokens (users.fcm_token) of the given users, so the field
//     app gets the same alerts. Only when user_ids is given (a broadcast stays web-only).
// The notification's inbox row is already written by notify_event__impl, so nothing is added to push_inbox here.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY")!;
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:iunisource@gmail.com";
const FUNCTION_SECRET = Deno.env.get("FUNCTION_SECRET") ?? "";
const FCM_SERVICE_ACCOUNT = Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "";

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// OAuth2 access token from the Firebase service account (same as send-notification).
async function getAccessToken(serviceAccount: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const encode = (obj: any) =>
    btoa(JSON.stringify(obj)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const signingInput = `${encode(header)}.${encode(payload)}`;
  const pemBody = String(serviceAccount.private_key)
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\n/g, "");
  const keyData = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyData.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  const sig = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${signingInput}.${sig}`,
  });
  const tokenData = await tokenRes.json();
  return tokenData.access_token;
}

// Firebase push to the phones of [userIds]. Never throws: a failure here must not hide the web push result.
async function sendFcm(
  orgId: string,
  userIds: string[],
  title: string,
  body: string,
  url: string,
): Promise<{ fcm_tokens: number; fcm_sent: number; fcm_failed: number; fcm_error?: string }> {
  const out = { fcm_tokens: 0, fcm_sent: 0, fcm_failed: 0 } as {
    fcm_tokens: number; fcm_sent: number; fcm_failed: number; fcm_error?: string;
  };
  try {
    if (!FCM_SERVICE_ACCOUNT) return { ...out, fcm_error: "FCM_SERVICE_ACCOUNT not set" };
    const { data: users, error } = await supabase
      .from("users")
      .select("id, fcm_token")
      .eq("org_id", orgId)
      .in("id", userIds);
    if (error) return { ...out, fcm_error: error.message };
    const tokens = [...new Set((users ?? []).map((u: any) => u.fcm_token).filter((t: any) => !!t))] as string[];
    out.fcm_tokens = tokens.length;
    if (tokens.length === 0) return out;

    const serviceAccount = JSON.parse(FCM_SERVICE_ACCOUNT);
    const accessToken = await getAccessToken(serviceAccount);
    const projectId = serviceAccount.project_id;
    const data: Record<string, string> = { type: "notify_event", link_url: url, url };

    const results = await Promise.all(tokens.map(async (token) => {
      try {
        const res = await fetch(
          `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
          {
            method: "POST",
            headers: { "Content-Type": "application/json", "Authorization": `Bearer ${accessToken}` },
            body: JSON.stringify({
              message: {
                token,
                notification: { title, body },
                data,
                android: { priority: "high", notification: { sound: "default" } },
              },
            }),
          },
        );
        return res.ok;
      } catch (_) {
        return false;
      }
    }));
    for (const ok of results) ok ? out.fcm_sent++ : out.fcm_failed++;
    return out;
  } catch (e: any) {
    return { ...out, fcm_error: String(e?.message ?? e) };
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  if (!FUNCTION_SECRET || req.headers.get("x-webhook-secret") !== FUNCTION_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }

  const orgId = payload?.org_id;
  if (!orgId) return json({ error: "org_id required" }, 400);

  const userIds: string[] | undefined =
    Array.isArray(payload?.user_ids) && payload.user_ids.length > 0
      ? payload.user_ids
      : undefined;

  const title = payload.title ?? "Opstation";
  const body = payload.body ?? "Something needs your attention";
  const url = payload.url ?? "/";

  // Phones first/alongside: runs whether or not there are any browser subscriptions.
  const fcmPromise = userIds ? sendFcm(orgId, userIds, title, body, url) : Promise.resolve(null);

  let query = supabase.from("push_subscriptions").select("*").eq("org_id", orgId);
  if (userIds) query = query.in("user_id", userIds);
  const { data: subs, error } = await query;
  if (error) {
    const fcm = await fcmPromise;
    return json({ error: error.message, ...(fcm ?? {}) }, 500);
  }

  let sent = 0;
  let removed = 0;
  if (subs && subs.length > 0) {
    const message = JSON.stringify({ title, body, url, tag: payload.tag ?? undefined });
    for (const s of subs) {
      const subscription = {
        endpoint: s.endpoint,
        keys: { p256dh: s.p256dh, auth: s.auth },
      };
      try {
        await webpush.sendNotification(subscription, message);
        sent++;
      } catch (e: any) {
        const code = e?.statusCode;
        if (code === 404 || code === 410) {
          await supabase.from("push_subscriptions").delete().eq("endpoint", s.endpoint);
          removed++;
        }
      }
    }
  }

  const fcm = await fcmPromise;
  return json({ ok: true, subscriptions: subs?.length ?? 0, sent, removed, ...(fcm ?? {}) });
});
