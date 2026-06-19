// Public asset data API — backs the scannable asset page.
//
// Supabase Edge Functions cannot serve HTML (text/html GETs are rewritten to
// text/plain by the runtime), so this returns JSON. The rendered page is a
// static file hosted on Firebase (web/asset.html) that fetches this endpoint.
//
// No auth (deploy with --no-verify-jwt). Looks the asset up by its opaque
// public_token using the service role; only non-sensitive fields are returned
// (no purchase cost / supplier). RLS on the tables stays fully closed.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "*",
  "access-control-allow-methods": "GET, OPTIONS",
};

const enc = (s: string) => encodeURIComponent(s);
const BUCKET = "asset-files";

async function rest(path: string): Promise<any[]> {
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    });
    if (!r.ok) return [];
    return await r.json();
  } catch (_) {
    return [];
  }
}

async function imagePathFor(
  assetId: string,
  imagePath?: string | null,
): Promise<string | null> {
  if (imagePath) return imagePath;
  const f = await rest(
    `asset_files?asset_id=eq.${enc(assetId)}&file_type=eq.image` +
      `&order=created_at.desc&limit=1&select=storage_path`,
  );
  return f[0]?.storage_path ?? null;
}

async function signedUrl(path: string): Promise<string | null> {
  try {
    const objectPath = path.split("/").map(encodeURIComponent).join("/");
    const r = await fetch(
      `${SUPABASE_URL}/storage/v1/object/sign/${BUCKET}/${objectPath}`,
      {
        method: "POST",
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ expiresIn: 3600 }),
      },
    );
    if (!r.ok) return null;
    const j = await r.json();
    return j?.signedURL ? `${SUPABASE_URL}/storage/v1${j.signedURL}` : null;
  } catch (_) {
    return null;
  }
}

const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

function fmtDate(d?: string | null): string {
  if (!d) return "—";
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d);
  if (!m) return d;
  return `${parseInt(m[3], 10)} ${MONTHS[parseInt(m[2], 10) - 1]} ${m[1]}`;
}

function title(s?: string | null): string {
  if (!s) return "";
  return s.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

function money(n: unknown): string {
  const v = Number(n);
  if (!isFinite(v)) return "";
  return "Rs " + v.toLocaleString("en-PK");
}

function statusClass(s?: string | null): string {
  switch ((s ?? "").toLowerCase().replace(/_/g, " ").trim()) {
    case "in use": return "ok";
    case "in storage": return "info";
    case "under repair": return "warn";
    case "lost": return "bad";
    case "retired":
    case "disposed": return "muted";
    default: return "muted";
  }
}

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
      ...CORS,
    },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

  const token = new URL(req.url).searchParams.get("t") ?? "";
  if (!token) return json({ error: "missing_token" }, 400);

  const assets = await rest(
    `assets?public_token=eq.${enc(token)}&is_active=eq.true&limit=1&select=` +
      `id,asset_code,name,description,status,condition,serial_no,model,manufacturer,` +
      `category_id,branch_id,location_text,assigned_to,org_id,next_maintenance_due,image_path`,
  );
  const a = assets[0];
  if (!a) return json({ error: "not_found" }, 404);

  const [branch] = a.branch_id
    ? await rest(`branches?id=eq.${enc(a.branch_id)}&select=name&limit=1`)
    : [];
  const [cust] = a.assigned_to
    ? await rest(`asset_custodians?id=eq.${enc(a.assigned_to)}&select=name&limit=1`)
    : [];
  const [cat] = a.category_id
    ? await rest(`asset_categories?id=eq.${enc(a.category_id)}&select=name&limit=1`)
    : [];
  const org = await rest(`organizations?id=eq.${enc(a.org_id)}&select=name&limit=1`);
  const orgName = org[0]?.name ?? null;

  const maintRows = await rest(
    `asset_maintenance?asset_id=eq.${enc(a.id)}&order=service_date.desc` +
      `&select=service_date,type,cost,vendor,note,next_due`,
  );

  const imgPath = await imagePathFor(a.id, a.image_path);
  const imageUrl = imgPath ? await signedUrl(imgPath) : null;

  // Next-maintenance banner
  let dueLabel: string | null = null;
  let dueClass = "ok";
  if (a.next_maintenance_due) {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const due = new Date(a.next_maintenance_due + "T00:00:00");
    const days = Math.round((due.getTime() - today.getTime()) / 86400000);
    dueClass = days < 0 ? "bad" : days <= 14 ? "warn" : "ok";
    const tail = days < 0 ? " · overdue" : days <= 14 ? " · due soon" : "";
    dueLabel = `Next maintenance due: ${fmtDate(a.next_maintenance_due)}${tail}`;
  }

  const maintenance = maintRows.map((m) => {
    const detail = [
      title(m.type),
      m.vendor ?? "",
    ].filter(Boolean).join(" · ") + (m.note ? ` — ${m.note}` : "");
    return {
      detail: detail || "—",
      date: fmtDate(m.service_date),
      next: fmtDate(m.next_due),
    };
  });

  return json({
    code: a.asset_code ?? "",
    name: a.name ?? "",
    statusLabel: title(a.status),
    statusClass: statusClass(a.status),
    condition: title(a.condition) || null,
    serial: a.serial_no ?? null,
    category: cat?.name ?? null,
    model: a.model ?? null,
    manufacturer: a.manufacturer ?? null,
    description: a.description ?? null,
    branch: branch?.name ?? null,
    location: a.location_text ?? null,
    custodian: cust?.name ?? null,
    orgName,
    dueLabel,
    dueClass,
    imageUrl,
    maintenance,
  });
});
