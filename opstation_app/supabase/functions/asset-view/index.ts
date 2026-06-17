// Public asset view — opened when someone scans an asset's QR tag.
//
// No auth (deploy with --no-verify-jwt). Looks the asset up by its opaque
// public_token using the service role, then renders a clean, mobile-friendly
// HTML page. Only non-sensitive fields are shown (name, code, serial, spec,
// placement, maintenance log) — purchase cost / supplier are deliberately
// omitted. RLS on the underlying tables stays fully closed to the public.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const enc = (s: string) => encodeURIComponent(s);

const H = (s: unknown) =>
  String(s ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[
        c
      ]!),
  );

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

const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

function fmtDate(d?: string | null): string {
  if (!d) return "—";
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d);
  if (!m) return H(d);
  return `${parseInt(m[3], 10)} ${MONTHS[parseInt(m[2], 10) - 1]} ${m[1]}`;
}

function title(s?: string | null): string {
  if (!s) return "";
  return s
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

function money(n: unknown): string {
  const v = Number(n);
  if (!isFinite(v)) return "";
  return "Rs " + v.toLocaleString("en-PK");
}

function statusClass(s?: string | null): string {
  switch ((s ?? "").toLowerCase().replace(/_/g, " ").trim()) {
    case "in use":
      return "ok";
    case "in storage":
      return "info";
    case "under repair":
      return "warn";
    case "lost":
      return "bad";
    case "retired":
    case "disposed":
      return "muted";
    default:
      return "muted";
  }
}

const CSS = `
*{box-sizing:border-box}
body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:#f1f5f9;color:#0f172a;-webkit-text-size-adjust:100%}
.wrap{max-width:560px;margin:0 auto;padding:16px}
.head{background:#fff;border-radius:14px;padding:18px 18px 16px;border:1px solid #e2e8f0;border-left:4px solid #2563eb}
.org{font-size:12px;color:#64748b;margin:0 0 6px}
.name{font-size:22px;font-weight:800;margin:0;line-height:1.15}
.code{font-size:14px;color:#2563eb;font-weight:700;margin:4px 0 0}
.pill{display:inline-block;margin-top:10px;padding:4px 11px;border-radius:999px;font-size:11px;font-weight:700;letter-spacing:.4px;text-transform:uppercase}
.pill.ok{background:#dcfce7;color:#15803d}
.pill.info{background:#dbeafe;color:#2563eb}
.pill.warn{background:#fef3c7;color:#b45309}
.pill.bad{background:#fee2e2;color:#b91c1c}
.pill.muted{background:#f1f5f9;color:#475569}
.card{background:#fff;border-radius:14px;padding:16px 18px;border:1px solid #e2e8f0;margin-top:14px}
.card h2{font-size:11px;letter-spacing:.8px;text-transform:uppercase;color:#64748b;margin:0 0 12px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:14px 18px}
.kv .k{font-size:11px;color:#64748b;margin:0 0 2px}
.kv .v{font-size:14px;font-weight:700;margin:0}
.due{margin-top:14px;padding:12px 14px;border-radius:12px;font-weight:700;font-size:13px;border:1px solid}
.due.ok{background:#eff6ff;border-color:#bfdbfe;color:#1d4ed8}
.due.warn{background:#fef3c7;border-color:#b45309;color:#b45309}
.due.bad{background:#fee2e2;border-color:#dc2626;color:#dc2626}
table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;font-size:11px;color:#64748b;font-weight:700;padding:6px 8px;border-bottom:1px solid #e2e8f0}
td{padding:9px 8px;border-bottom:1px solid #f1f5f9;vertical-align:top}
tr:last-child td{border-bottom:0}
td.r,th.r{text-align:right;white-space:nowrap}
.muted-row td{color:#64748b}
.empty{color:#64748b;font-size:13px}
.foot{text-align:center;color:#94a3b8;font-size:11px;margin:18px 0 4px}
`;

function page(title: string, body: string, status = 200): Response {
  return new Response(
    `<!doctype html><html lang="en"><head><meta charset="utf-8">` +
      `<meta name="viewport" content="width=device-width, initial-scale=1">` +
      `<title>${H(title)}</title><style>${CSS}</style></head>` +
      `<body><div class="wrap">${body}<div class="foot">Opstation &middot; Asset register</div></div></body></html>`,
    {
      status,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
      },
    },
  );
}

Deno.serve(async (req) => {
  const token = new URL(req.url).searchParams.get("t") ?? "";
  if (!token) {
    return page("Invalid", `<div class="card empty">Invalid asset link.</div>`, 400);
  }

  const assets = await rest(
    `assets?public_token=eq.${enc(token)}&is_active=eq.true&limit=1&select=` +
      `id,asset_code,name,description,status,condition,serial_no,model,manufacturer,` +
      `category_id,branch_id,location_text,assigned_to,org_id,next_maintenance_due`,
  );
  const a = assets[0];
  if (!a) {
    return page(
      "Not found",
      `<div class="card empty"><strong>Asset not found.</strong><br>This tag may have been removed or replaced.</div>`,
      404,
    );
  }

  const [branch] = a.branch_id
    ? await rest(`branches?id=eq.${enc(a.branch_id)}&select=name&limit=1`)
    : [];
  const [cust] = a.assigned_to
    ? await rest(
      `asset_custodians?id=eq.${enc(a.assigned_to)}&select=name,phone&limit=1`,
    )
    : [];
  const [cat] = a.category_id
    ? await rest(`asset_categories?id=eq.${enc(a.category_id)}&select=name&limit=1`)
    : [];
  let orgName = "";
  const org = await rest(`organizations?id=eq.${enc(a.org_id)}&select=name&limit=1`);
  if (org[0]?.name) orgName = org[0].name;

  const maint = await rest(
    `asset_maintenance?asset_id=eq.${enc(a.id)}&order=service_date.desc` +
      `&select=service_date,type,cost,vendor,note,next_due`,
  );

  // Next-maintenance banner state
  let dueHtml = "";
  if (a.next_maintenance_due) {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const due = new Date(a.next_maintenance_due + "T00:00:00");
    const days = Math.round((due.getTime() - today.getTime()) / 86400000);
    const cls = days < 0 ? "bad" : days <= 14 ? "warn" : "ok";
    const tail = days < 0 ? " &middot; overdue" : days <= 14 ? " &middot; due soon" : "";
    dueHtml =
      `<div class="due ${cls}">Next maintenance due: ${fmtDate(a.next_maintenance_due)}${tail}</div>`;
  }

  const kv = (k: string, v: string) =>
    `<div class="kv"><p class="k">${H(k)}</p><p class="v">${v || "&mdash;"}</p></div>`;

  let maintHtml: string;
  if (!maint.length) {
    maintHtml = `<p class="empty">No maintenance recorded.</p>`;
  } else {
    const rows = maint
      .map((m) => {
        const detail = [
          title(m.type),
          m.cost != null ? money(m.cost) : "",
          m.vendor ? H(m.vendor) : "",
        ].filter(Boolean).join(" &middot; ") +
          (m.note ? ` &mdash; ${H(m.note)}` : "");
        return `<tr><td>${detail || "&mdash;"}</td><td class="r">${fmtDate(m.service_date)}</td><td class="r">${fmtDate(m.next_due)}</td></tr>`;
      })
      .join("");
    maintHtml =
      `<table><thead><tr><th>Detail</th><th class="r">Date</th><th class="r">Next due</th></tr></thead><tbody>${rows}</tbody></table>`;
  }

  const body = `
    <div class="head">
      ${orgName ? `<p class="org">${H(orgName)}</p>` : ""}
      <h1 class="name">${H(a.name)}</h1>
      <p class="code">${H(a.asset_code)}</p>
      ${a.status ? `<span class="pill ${statusClass(a.status)}">${H(title(a.status))}</span>` : ""}
    </div>

    ${dueHtml}

    <div class="card">
      <h2>Placement</h2>
      <div class="grid">
        ${kv("Branch", H(branch?.name))}
        ${kv("Location", H(a.location_text))}
        ${kv("Custodian", H(cust?.name))}
        ${kv("Condition", H(title(a.condition)))}
      </div>
    </div>

    <div class="card">
      <h2>Specification</h2>
      <div class="grid">
        ${kv("Serial no.", H(a.serial_no))}
        ${kv("Category", H(cat?.name))}
        ${kv("Model", H(a.model))}
        ${kv("Manufacturer", H(a.manufacturer))}
      </div>
      ${a.description ? `<div class="kv" style="margin-top:14px"><p class="k">Description</p><p class="v" style="font-weight:500">${H(a.description)}</p></div>` : ""}
    </div>

    <div class="card">
      <h2>Maintenance log</h2>
      ${maintHtml}
    </div>
  `;

  return page(`${a.asset_code} - ${a.name}`, body);
});
