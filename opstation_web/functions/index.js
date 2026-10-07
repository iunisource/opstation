// Opstation — Firebase functions.
//
// paLink: short share link for a Payment Advice  →  https://<app>/l/<share_code>
//   • WhatsApp / other apps fetch this URL to build the preview card. We answer
//     with Open Graph tags: org logo as the image, org name as the title, and the
//     PA number / amount / payee / status as the description.
//   • A person tapping the link is sent straight on to the live, read-only page
//     /#/pa/<public_token>, so they always see the current version.
// Data comes from the public RPC pa_share_meta (SQL 329) — no balances exposed.

const { onRequest } = require('firebase-functions/v2/https');

const SUPABASE_URL = 'https://xgptodkasmytddmdnbtb.supabase.co';
const SUPABASE_ANON =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhncHRvZGthc215dGRkbWRuYnRiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2NzA5MjUsImV4cCI6MjA5MjI0NjkyNX0.pc1VsvsvtnkBHyRzuXzzuspSTJRqU_BQgQulMQ9UCac';

const esc = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const money = (v) => {
  const n = Number(v || 0);
  const whole = Math.abs(n - Math.round(n)) < 0.005;
  return 'Rs ' + n.toLocaleString('en-US', { minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: whole ? 0 : 2 });
};

const fmtDate = (d) => {
  const t = new Date(String(d || '') + 'T00:00:00Z');
  if (isNaN(t)) return '';
  return t.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
};

async function meta(code) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/pa_share_meta`, {
    method: 'POST',
    headers: { apikey: SUPABASE_ANON, Authorization: `Bearer ${SUPABASE_ANON}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_code: code }),
  });
  if (!r.ok) throw new Error('rpc ' + r.status);
  return r.json();
}

function page({ url, title, description, image, target, heading, sub, statusLabel = '', statusColor = '#6B7280' }) {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="${esc(title)}">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${esc(url)}">
<meta property="og:image" content="${esc(image)}">
<meta property="og:image:alt" content="${esc(title)}">
<meta name="twitter:card" content="summary">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(description)}">
<meta name="twitter:image" content="${esc(image)}">
<meta name="robots" content="noindex">
<style>
  body{margin:0;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;background:#F5F7FB;color:#0F1729;display:flex;min-height:100vh;align-items:center;justify-content:center}
  .card{background:#fff;border:1px solid #E5E7EB;border-radius:16px;padding:28px 24px;max-width:380px;width:calc(100% - 32px);text-align:center;box-shadow:0 8px 24px rgba(15,23,41,.06)}
  .logo{width:72px;height:72px;object-fit:contain;border-radius:12px}
  h1{font-size:20px;margin:12px 0 4px}
  p{margin:4px 0;color:#6B7280;font-size:14px;line-height:1.45}
  .pill{display:inline-block;margin-top:10px;padding:4px 10px;border-radius:999px;font-size:11px;font-weight:800;letter-spacing:1px;color:${statusColor};background:${statusColor}1a}
  a.btn{display:block;margin-top:20px;padding:14px;border-radius:10px;background:#2F6FED;color:#fff;text-decoration:none;font-weight:700;font-size:15px}
  .link{margin-top:10px;font-size:12px;color:#9CA3AF;word-break:break-all}
</style>
</head><body>
<div class="card">
  ${image ? `<img class="logo" src="${esc(image)}" alt="">` : ''}
  <h1>${esc(heading)}</h1>
  <p>${esc(sub)}</p>
  ${statusLabel ? `<span class="pill">${esc(statusLabel)}</span>` : ''}
  ${target ? `<a class="btn" href="${esc(target)}">Open Link</a>` : ''}
  <div class="link">${esc(url)}</div>
</div>
${target ? `<script>location.replace(${JSON.stringify(target)});</script>` : ''}
</body></html>`;
}

async function handle(req, res) {
  const host = req.get('x-forwarded-host') || req.get('host');
  const origin = `https://${host}`;
  const code = (req.path.split('/').filter(Boolean).pop() || '').trim();
  const url = `${origin}/l/${code}`;
  const fallbackImg = `${origin}/icons/Icon-512.png`;

  res.set('Content-Type', 'text/html; charset=utf-8');
  res.set('Cache-Control', 'public, max-age=60, s-maxage=120');

  let m = null;
  if (/^[A-Za-z0-9]{6,12}$/.test(code)) {
    try { m = await meta(code); } catch (e) { console.error(e); }
  }
  if (!m || m.ok !== true) {
    res.status(404).send(page({
      origin, url, title: 'Payment Advice not found',
      description: 'This link is not valid or the payment advice no longer exists.',
      image: fallbackImg, target: null,
      heading: 'Link not found', sub: 'This link is not valid or the payment advice no longer exists.',
    }));
    return;
  }

  const org = m.org_name || 'Payment Advice';
  const status = m.status || 'approved';
  const [label, color, prefix] =
    status === 'void' ? ['CANCELLED', '#B91C1C', '❌ CANCELLED — ']
    : status === 'rejected' ? ['REJECTED', '#B91C1C', '❌ REJECTED — ']
    : status === 'pending' ? ['PENDING APPROVAL', '#B45309', '⏳ Pending approval — ']
    : ['APPROVED', '#15803D', ''];
  const payees = Number(m.payees || 0);
  const who = m.first_payee ? (payees > 1 ? `${m.first_payee} +${payees - 1} more` : m.first_payee) : '';
  const parts = [`Payment Advice ${m.advice_number || ''}`.trim(), money(m.grand_total), who, fmtDate(m.advice_date)].filter(Boolean);
  const description = prefix + parts.join(' · ') + ' — tap to open';

  res.status(200).send(page({
    origin, url,
    title: org,
    description,
    image: m.logo_url || fallbackImg,
    target: `${origin}/#/pa/${m.token}`,
    heading: org,
    sub: parts.join(' · '),
    statusLabel: label, statusColor: color,
  }));
}

exports.paLink = onRequest({ region: 'us-central1', memory: '256MiB', maxInstances: 5 }, handle);
exports._handle = handle; // for local testing
