// Public facility-area status API — backs the per-area QR page.
//
// Edge Functions can't serve HTML, so this returns JSON; the rendered page is
// the static area.html on Firebase. No auth (deploy with --no-verify-jwt).
// Looks the area up by its opaque public_token (service role); shows what's
// due here and what was recently done. RLS on the tables stays closed.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "*",
  "access-control-allow-methods": "GET, OPTIONS",
};
const enc = (s: string) => encodeURIComponent(s);

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

const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
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
function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...CORS },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

  const token = new URL(req.url).searchParams.get("t") ?? "";
  if (!token) return json({ error: "missing_token" }, 400);

  const areas = await rest(
    `facility_areas?public_token=eq.${enc(token)}&is_active=eq.true&limit=1` +
      `&select=id,name,area_type,branch_id,org_id`,
  );
  const a = areas[0];
  if (!a) return json({ error: "not_found" }, 404);

  const [branch] = a.branch_id
    ? await rest(`branches?id=eq.${enc(a.branch_id)}&select=name&limit=1`)
    : [];
  const org = await rest(`organizations?id=eq.${enc(a.org_id)}&select=name&limit=1`);

  const openRows = await rest(
    `facility_tasks?area_id=eq.${enc(a.id)}&status=eq.open&order=due_date` +
      `&select=title,category,due_date`,
  );
  const doneRows = await rest(
    `facility_tasks?area_id=eq.${enc(a.id)}&status=eq.done&order=completed_at.desc&limit=8` +
      `&select=title,completed_at,completed_by`,
  );

  // resolve completed_by -> name
  const ids = [...new Set(doneRows.map((d) => d.completed_by).filter(Boolean))];
  const nameById: Record<string, string> = {};
  if (ids.length) {
    const us = await rest(
      `users?id=in.(${ids.map((i) => enc(i)).join(",")})&select=id,name`,
    );
    for (const u of us) nameById[u.id] = u.name;
  }

  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const open = openRows.map((t) => {
    const overdue = !!t.due_date &&
      new Date(t.due_date + "T00:00:00").getTime() < today.getTime();
    return { title: t.title, category: title(t.category), due: fmtDate(t.due_date), overdue };
  });
  const recent = doneRows.map((t) => ({
    title: t.title,
    date: fmtDate(t.completed_at),
    by: nameById[t.completed_by] ?? "",
  }));

  return json({
    name: a.name ?? "",
    areaType: title(a.area_type),
    branch: branch?.name ?? null,
    orgName: org[0]?.name ?? null,
    counts: { open: open.length, overdue: open.filter((o) => o.overdue).length },
    open,
    recent,
  });
});
