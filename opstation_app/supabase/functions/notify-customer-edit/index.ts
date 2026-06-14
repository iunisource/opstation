// Supabase Edge Function: notify-customer-edit
// Sends an email alert to org-configured recipients when a customer is edited.
// Org, acting user, and config (toggle + recipients) are resolved SERVER-SIDE
// from the caller's JWT + service role — the client only passes the customer
// name and the list of changed fields.
//
// Deploy:   supabase functions deploy notify-customer-edit
// Secrets:  supabase secrets set GMAIL_USER="iunisource@gmail.com" \
//                                GMAIL_APP_PASSWORD="<16-char app password>"
//           (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY are
//            injected automatically.)

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

function escapeHtml(s: string): string {
  return String(s).replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" } as Record<string, string>)[c]
  );
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const { customerName, changes } = await req.json();
    const authHeader = req.headers.get("Authorization") ?? "";
    const url = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

    // Who is calling?
    const authClient = createClient(url, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const {
      data: { user },
    } = await authClient.auth.getUser();
    if (!user) return json({ error: "unauthorized" }, 401);

    const admin = createClient(url, serviceKey);

    // auth email -> public.users (org_id + display name)
    const { data: pu } = await admin
      .from("users")
      .select("org_id, name")
      .ilike("email", user.email ?? "")
      .maybeSingle();
    if (!pu?.org_id) return json({ error: "no org for caller" }, 400);
    const orgId = pu.org_id as string;
    const userName = (pu.name as string | null) ?? user.email ?? "A user";

    // Toggle + recipients from app_config (org-scoped)
    const { data: cfgRows } = await admin
      .from("app_config")
      .select("key, value")
      .eq("org_id", orgId)
      .in("key", ["org.customer_edit_alert", "org.customer_edit_alert_emails"]);
    const cfg: Record<string, string> = {};
    for (const r of cfgRows ?? []) cfg[r.key as string] = (r.value as string) ?? "";

    if (cfg["org.customer_edit_alert"] !== "true") {
      return json({ skipped: "alert disabled" });
    }
    const recipients = (cfg["org.customer_edit_alert_emails"] ?? "")
      .split(/[\s,;]+/)
      .map((s) => s.trim())
      .filter(Boolean);
    if (recipients.length === 0) return json({ skipped: "no recipients" });

    const changeList = Array.isArray(changes)
      ? changes.join(", ")
      : String(changes ?? "");
    const safeCustomer = String(customerName ?? "(unknown customer)");

    const subject = `Customer edited: ${safeCustomer}`;
    const text =
      `${userName} edited customer "${safeCustomer}".\n` +
      `Changed: ${changeList}\n\n` +
      `Automated Opstation audit alert.`;
    const html =
      `<p><b>${escapeHtml(userName)}</b> edited customer ` +
      `<b>${escapeHtml(safeCustomer)}</b>.</p>` +
      `<p>Changed: ${escapeHtml(changeList)}</p>` +
      `<p style="color:#888;font-size:12px">Automated Opstation audit alert.</p>`;

    const gmailUser = Deno.env.get("GMAIL_USER")!;
    const gmailPass = Deno.env.get("GMAIL_APP_PASSWORD")!;
    const client = new SMTPClient({
      connection: {
        hostname: "smtp.gmail.com",
        port: 465,
        tls: true,
        auth: { username: gmailUser, password: gmailPass },
      },
    });
    await client.send({
      from: `Opstation <${gmailUser}>`,
      to: recipients,
      subject,
      content: text,
      html,
    });
    await client.close();

    return json({ sent: recipients.length });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
