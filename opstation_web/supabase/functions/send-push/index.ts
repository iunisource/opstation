// Supabase Edge Function: send-push
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY")!;
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:iunisource@gmail.com";
const FUNCTION_SECRET = Deno.env.get("FUNCTION_SECRET") ?? "";

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

  let query = supabase.from("push_subscriptions").select("*").eq("org_id", orgId);
  if (userIds) query = query.in("user_id", userIds);
  const { data: subs, error } = await query;
  if (error) return json({ error: error.message }, 500);
  if (!subs || subs.length === 0) {
    return json({ ok: true, subscriptions: 0, sent: 0, removed: 0 });
  }

  const message = JSON.stringify({
    title: payload.title ?? "Opstation",
    body: payload.body ?? "Something needs your attention",
    url: payload.url ?? "/",
    tag: payload.tag ?? undefined,
  });

  let sent = 0;
  let removed = 0;
  for (const s of subs ?? []) {
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

  return json({ ok: true, subscriptions: subs?.length ?? 0, sent, removed });
});