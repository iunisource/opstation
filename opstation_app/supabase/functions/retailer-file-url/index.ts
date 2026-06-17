// supabase/functions/retailer-file-url/index.ts
//
// Returns a short-lived signed URL for a shared_files row the calling
// retailer is entitled to. Retailers can't sign objects in the private
// `retailer-files` bucket directly (storage RLS blocks them), so this
// function: (1) re-uses the caller's own JWT to call retailer_my_files()
// — which already enforces "all" / own-customer entitlement — to confirm
// the file is theirs and fetch its storage_path, then (2) mints the signed
// URL with the service role.
//
// Request:  { fileId: string }
// Response: { url: string }  |  { error: string }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "retailer-files";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "missing_auth" }, 401);

  let fileId: string | undefined;
  try {
    const body = await req.json();
    fileId = body?.fileId;
  } catch (_) {
    return json({ error: "bad_request" }, 400);
  }
  if (!fileId) return json({ error: "file_id_required" }, 400);

  // 1) Entitlement + storage_path via the caller's own RPC (runs as the
  //    retailer; retailer_my_files() only returns files shared with them).
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: files, error: rpcErr } = await userClient.rpc(
    "retailer_my_files",
  );
  if (rpcErr) return json({ error: "rpc_failed", detail: rpcErr.message }, 500);

  const file = (files as Array<Record<string, unknown>> | null)?.find(
    (f) => f.id === fileId,
  );
  if (!file) return json({ error: "not_entitled" }, 403);

  const storagePath = file.storage_path as string | undefined;
  if (!storagePath) return json({ error: "no_path" }, 500);

  // 2) Sign with the service role (private bucket).
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { data: signed, error: signErr } = await admin.storage
    .from(BUCKET)
    .createSignedUrl(storagePath, 3600);

  if (signErr || !signed) {
    return json({ error: "sign_failed", detail: signErr?.message }, 500);
  }

  return json({ url: signed.signedUrl });
});
