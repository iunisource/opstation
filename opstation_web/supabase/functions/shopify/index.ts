// Supabase Edge Function: shopify
// Connects Shopify stores to Opstation and keeps their orders in shop_orders
// (SQL 370) for Sales → Fulfillment.
//
// Callers
//   • Shopify notifications (orders created / updated / cancelled)
//       POST ?store=<store id>, signed with the app's client secret (HMAC).
//   • pg_cron every 10 min with the service key: {"action":"sync_all"}
//   • The app (signed-in user):
//       {action:"connect", shop_domain, client_id, client_secret, access_token?, name?, branch_id?, days?}
//       {action:"sync", store_id}
//       {action:"fulfill", order_id, company?, number?, url?, notify?}
//       {action:"refresh_order", order_id}
//       {action:"disconnect", store_id}
//       {action:"list_variants", store_id}   store items + suggested matches
//       {action:"rematch", store_id}         re-apply matches to open orders
//
// Deploy (Shopify's notifications carry no Supabase login, so JWT checking is
// done inside):
//   supabase functions deploy shopify --project-ref xgptodkasmytddmdnbtb --no-verify-jwt

// Pinned npm import: esm.sh's floating "@2" build broke bundling (Oct 2026).
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

const API_VERSION = "2026-07";
const FN_URL = "https://xgptodkasmytddmdnbtb.supabase.co/functions/v1/shopify";
const APP_URL = "https://opstation-f06c7.web.app";
const SCOPES = "read_orders,read_customers,read_products,read_merchant_managed_fulfillment_orders,write_merchant_managed_fulfillment_orders";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

type Store = { id: string; org_id: string; shop_domain: string; name: string | null; branch_id: string | null; is_active: boolean; match_groups?: string[] | null; sku_rules?: unknown };
type Secret = { store_id: string; client_id: string | null; client_secret: string | null; access_token: string | null; token_expires_at: string | null };

function jwtPayload(token: string): Record<string, unknown> | null {
  try {
    const p = token.split(".")[1];
    if (!p) return null;
    return JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/")));
  } catch {
    return null;
  }
}

function normDomain(d: string): string {
  let s = (d || "").trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
  if (s && !s.includes(".")) s = `${s}.myshopify.com`;
  return s;
}

// ── Shopify access ────────────────────────────────────────────────────────────
async function getToken(admin: SupabaseClient, store: Store, sec: Secret): Promise<string> {
  const exp = sec.token_expires_at ? Date.parse(sec.token_expires_at) : null;
  if (sec.access_token && (exp === null || exp - Date.now() > 5 * 60 * 1000)) return sec.access_token;
  if (!sec.client_id || !sec.client_secret) throw new Error("No access key for this store — connect it again.");
  const r = await fetch(`https://${store.shop_domain}/admin/oauth/access_token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: sec.client_id, client_secret: sec.client_secret }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`Shopify refused the app key (${r.status}): ${t.slice(0, 200)}`);
  const j = JSON.parse(t);
  const expiresAt = new Date(Date.now() + (Number(j.expires_in) || 86399) * 1000).toISOString();
  await admin.from("shop_store_secrets").update({ access_token: j.access_token, token_expires_at: expiresAt }).eq("store_id", store.id);
  sec.access_token = j.access_token;
  sec.token_expires_at = expiresAt;
  return j.access_token;
}

async function gql(admin: SupabaseClient, store: Store, sec: Secret, query: string, variables: Record<string, unknown> = {}) {
  const token = await getToken(admin, store, sec);
  const r = await fetch(`https://${store.shop_domain}/admin/api/${API_VERSION}/graphql.json`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": token },
    body: JSON.stringify({ query, variables }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`Shopify ${r.status}: ${t.slice(0, 300)}`);
  const j = JSON.parse(t);
  if (j.errors) throw new Error(`Shopify: ${JSON.stringify(j.errors).slice(0, 300)}`);
  return j.data;
}

const ORDER_FIELDS = `
  id name createdAt updatedAt cancelledAt displayFinancialStatus displayFulfillmentStatus
  email phone note paymentGatewayNames
  totalPriceSet { shopMoney { amount currencyCode } }
  customer { displayName email phone }
  shippingAddress { name address1 address2 city province zip country phone }
  lineItems(first: 100) { nodes { id title variantTitle sku quantity currentQuantity
    originalUnitPriceSet { shopMoney { amount } } variant { id barcode sku } } }`;

// Same, without product details — used when the app doesn't have the
// read_products permission yet (matching then works by SKU only).
const ORDER_FIELDS_LITE = ORDER_FIELDS.replace("variant { id barcode sku }", "");

/// Runs an orders query; if Shopify denies product details, retries without them.
async function gqlOrders(admin: SupabaseClient, store: Store, sec: Secret, build: (fields: string) => string,
    variables: Record<string, unknown>) {
  try {
    return await gql(admin, store, sec, build(ORDER_FIELDS), variables);
  } catch (e) {
    if (/read_products|ACCESS_DENIED/i.test((e as Error).message)) {
      return await gql(admin, store, sec, build(ORDER_FIELDS_LITE), variables);
    }
    throw e;
  }
}

// ── Matching store items to Opstation products ───────────────────────────────
// Works with any store's SKU style — nothing is hard-wired to one brand:
//   • exact: store SKU / barcode = Opstation barcode or SKU
//   • code:  the store SKU is the start of an Opstation product name or equals
//            its SKU, ignoring spaces / dashes / case ("ALA301" = "ALA 301-…",
//            "TS-001" = "TS 001 Blue T-shirt")
//   • a qualifier in brackets — "X 12 (S)" — picks, among the same-code
//            products, the one with a word starting with it ("Special …")
//   • several codes joined with + , ; & | make a bundle; "2x CODE" / "CODE x2"
//   • every choice made by hand is remembered per code and reused everywhere
//     (also inside bundles), so the store teaches itself.
// Only products in the store's chosen main groups are considered (default:
// the finished-goods group), so boxes, raw and parts never get picked.
function toks(s: string): string[] {
  return String(s ?? "").toUpperCase()
    .replace(/([A-Z])(?=\d)|(\d)(?=[A-Z])/g, "$1$2 ")
    .split(/[^A-Z0-9]+/).filter(Boolean);
}
// How a store writes its SKUs — set per store in Match products → SKU rules
// (shop_stores.sku_rules). Missing keys fall back to these defaults.
type Rules = {
  separators: string;            // characters that join a bundle: "+,;&|"
  qty_before: boolean;           // "3x CODE"
  qty_after: boolean;            // "CODE x3"
  qty_brackets: boolean;         // "CODE (3)", "(3 pcs)"
  tags: Array<{ tag: string; word: string }>;  // "(S)" → product name has "special"
  auto_tags: boolean;            // unknown "(X)" → a name word starting with X
};
const DEFAULT_RULES: Rules = { separators: "+,;&|", qty_before: true, qty_after: true, qty_brackets: true, tags: [], auto_tags: true };
// deno-lint-ignore no-explicit-any
function rulesOf(raw: any): Rules {
  const r = { ...DEFAULT_RULES, ...(raw && typeof raw === "object" ? raw : {}) } as Rules;
  r.separators = typeof r.separators === "string" ? r.separators.replace(/\s/g, "") : DEFAULT_RULES.separators;
  r.tags = Array.isArray(r.tags)
    ? r.tags.filter((t) => t && String(t.tag ?? "").trim() && String(t.word ?? "").trim())
        .map((t) => ({ tag: String(t.tag).replace(/[()\s]/g, "").toUpperCase(), word: String(t.word).trim().toUpperCase() }))
    : [];
  return r;
}
const esc = (c: string) => c.replace(/[-\\^\]\[]/g, "\\$&");

type Seg = { code: string; core: string; key: string; base: string; q: string | null; qty: number };
function parseSegs(rules: Rules, s: string): Seg[] {
  const out: Seg[] = [];
  const sep = rules.separators ? new RegExp(`\\s*[${[...rules.separators].map(esc).join("")}]\\s*`) : null;
  for (let part of (sep ? String(s ?? "").split(sep) : [String(s ?? "")])) {
    part = part.trim();
    if (!part) continue;
    let qty = 1;
    let m: RegExpMatchArray | null = null;
    if (rules.qty_before && (m = part.match(/^(\d{1,3})\s*[xX×*]\s+|^(\d{1,3})\s*[xX×*](?=[A-Za-z])/))) {
      qty = Number(m[1] ?? m[2]); part = part.slice(m[0].length);
    } else if (rules.qty_after && (m = part.match(/\s*[xX×*]\s*(\d{1,3})$/)) && part.length > m[0].length) {
      qty = Number(m[1]); part = part.slice(0, -m[0].length);
    }
    // Trailing brackets: a number is the quantity — "(3)", "(x3)", "(3 pcs)";
    // anything else is a tag — "(S)". "ALA 111 (S) (3)" = 3 × ALA 111 (S).
    let q: string | null = null;
    for (let i = 0; i < 3; i++) {
      const qm = part.match(/\(\s*([^()]{1,12}?)\s*\)\s*$/);
      if (!qm) break;
      const n = rules.qty_brackets ? qm[1].match(/^(?:[xX×*]\s*)?(\d{1,3})\s*(?:[xX×*]|pcs?|pieces?|units?|nos?|sets?)?\.?$/i) : null;
      if (n) qty = Number(n[1]);
      else if (!q) q = qm[1].toUpperCase();
      part = part.slice(0, -qm[0].length).trim();
    }
    const base = toks(part).join(" ");
    if (!base) continue;
    const key = q ? `${base}|${toks(q).join(" ")}` : base;
    const ex = out.find((x) => x.key === key);
    if (ex) { ex.qty += Math.max(1, qty); continue; }
    out.push({ code: q ? `${part.trim()} (${q})` : part.trim(), core: part.trim(), key, base, q, qty: Math.max(1, qty) });
  }
  return out;
}

type Part = { product_id: string; qty: number };
type Mapped = { product_id: string | null; components: Part[] | null };
type SuggestPart = { code: string | null; key: string | null; qty: number; product_id: string | null; choices: string[] };
type Suggestion = { how: string; parts: SuggestPart[] };
type Prod = { id: string; name: string; nt: string[]; words: string[]; sk: string; bc: string };
type Catalog = {
  byCode: Map<string, string>;          // exact barcode / SKU (any product)
  byFirst: Map<string, Prod[]>;         // first name/SKU token → finished products
  learned: Map<string, string>;         // code key → product chosen before
  claimed: Map<string, Set<string>>;    // base code → products taken by a qualifier
  map: Map<string, Mapped>;             // saved matches per store item
  groups: string[];
  allGroups: Record<string, number>;
  rules: Rules;
};

function finishedDefault(all: string[]): string[] {
  const f = all.filter((g) => /finish/i.test(g));
  return f.length ? f : all.filter((g) => !/raw|pre-?\s?produc|packag|marketing|promotion/i.test(g));
}

async function loadCatalog(admin: SupabaseClient, store: Store): Promise<Catalog> {
  // deno-lint-ignore no-explicit-any
  const prods: any[] = [];
  for (let from = 0; ; from += 1000) {
    const { data } = await admin.from("products").select("id, name, sku, barcode, product_main_group")
      .eq("org_id", store.org_id).eq("is_active", true).range(from, from + 999);
    prods.push(...(data ?? []));
    if (!data || data.length < 1000) break;
  }
  const grp = (p: { product_main_group?: string | null }) => String(p.product_main_group ?? "").trim() || "(none)";
  const allGroups: Record<string, number> = {};
  for (const p of prods) allGroups[grp(p)] = (allGroups[grp(p)] ?? 0) + 1;
  const chosen = Array.isArray(store.match_groups) && store.match_groups.length
    ? store.match_groups : finishedDefault(Object.keys(allGroups));
  const inGroup = new Set(chosen);

  const byCode = new Map<string, string>();
  const byFirst = new Map<string, Prod[]>();
  const push = (k: string, p: Prod) => { if (!byFirst.has(k)) byFirst.set(k, []); if (!byFirst.get(k)!.includes(p)) byFirst.get(k)!.push(p); };
  for (const p of prods) {
    if (p.barcode) byCode.set(`b:${String(p.barcode).trim().toLowerCase()}`, p.id);
    if (p.sku) byCode.set(`s:${String(p.sku).trim().toLowerCase()}`, p.id);
    if (!inGroup.has(grp(p))) continue;
    const nt = toks(p.name ?? "");
    const pr: Prod = { id: p.id, name: p.name ?? "", nt, words: nt, sk: toks(p.sku ?? "").join(" "),
      bc: String(p.barcode ?? "").trim().toUpperCase() };
    if (nt.length) push(nt[0], pr);
    const st = toks(p.sku ?? "");
    if (st.length) push(st[0], pr);
  }
  const map = new Map<string, Mapped>();
  const learned = new Map<string, string>();
  const claimed = new Map<string, Set<string>>();
  const { data: m } = await admin.from("shop_product_map").select("ext_key, product_id, components").eq("store_id", store.id);
  for (const r of m ?? []) {
    if (String(r.ext_key).startsWith("code:")) {
      if (!r.product_id) continue;
      const key = String(r.ext_key).slice(5);
      learned.set(key, r.product_id);
      const [base, q] = key.split("|");
      if (q) { if (!claimed.has(base)) claimed.set(base, new Set()); claimed.get(base)!.add(r.product_id); }
      continue;
    }
    map.set(r.ext_key, { product_id: r.product_id ?? null, components: (r.components as Part[] | null) ?? null });
  }
  return { byCode, byFirst, learned, claimed, map, groups: chosen, allGroups, rules: rulesOf(store.sku_rules) };
}

// Finished products this code could be.
function candidates(cat: Catalog, s: Seg): Prod[] {
  const t = s.base.split(" ");
  const out: Prod[] = [];
  for (const p of cat.byFirst.get(t[0]) ?? []) {
    const starts = t.length <= p.nt.length && t.every((x, i) => p.nt[i] === x);
    if (starts || p.sk === s.base || (p.bc && p.bc === s.core.toUpperCase())) out.push(p);
  }
  return out;
}

function resolveSeg(cat: Catalog, s: Seg): SuggestPart {
  const part = (pid: string | null, choices: Prod[]): SuggestPart =>
    ({ code: s.code, key: s.key, qty: s.qty, product_id: pid, choices: choices.map((p) => p.id) });
  const known = cat.learned.get(s.key);
  if (known) return part(known, []);
  const cands = candidates(cat, s);
  if (cands.length <= 1) return part(cands[0]?.id ?? null, cands);
  if (s.q) {
    // A tag set in the store's rules: "(S)" → name has "special".
    const tag = cat.rules.tags.find((t) => t.tag === s.q!.replace(/[()\s]/g, ""));
    let has: ((p: Prod) => boolean) | null = null;
    if (tag) {
      has = (p: Prod) => p.name.toUpperCase().includes(tag.word);
    } else if (cat.rules.auto_tags) {
      // Otherwise: the one with a word starting with the tag that the others don't all share.
      const q = toks(s.q);
      has = (p: Prod) => q.every((x) => p.words.slice(s.base.split(" ").length).some((w) => w.startsWith(x)));
    }
    if (!has) return part(null, cands);
    const hit = cands.filter(has);
    if (hit.length && hit.length < cands.length) return part(hit.length === 1 ? hit[0].id : null, hit);
    return part(null, cands);
  }
  // Plain code: leave out the ones a qualifier already took ("ALA 301" vs "ALA 301 (S)").
  const taken = cat.claimed.get(s.base);
  const rest = taken ? cands.filter((p) => !taken.has(p.id)) : cands;
  if (rest.length === 1) return part(rest[0].id, rest);
  // Shortest name = the plain version, if the others only add words to it.
  const sorted = [...rest].sort((a, b) => a.nt.length - b.nt.length);
  return part(null, sorted.length ? sorted : cands);
}

// What a store item should be, without any saved choice.
function autoSuggest(cat: Catalog, sku: string, barcode: string, title: string): Suggestion {
  const one = (how: string, id?: string): Suggestion => ({ how, parts: [{ code: null, key: null, qty: 1, product_id: id ?? null, choices: [] }] });
  const b = barcode.toLowerCase(), s = sku.toLowerCase();
  if (b && cat.byCode.has(`b:${b}`)) return one("barcode", cat.byCode.get(`b:${b}`));
  if (s && cat.byCode.has(`b:${s}`)) return one("barcode", cat.byCode.get(`b:${s}`));
  if (s && cat.byCode.has(`s:${s}`)) return one("sku", cat.byCode.get(`s:${s}`));
  let parts = parseSegs(cat.rules, sku).map((x) => resolveSeg(cat, x));
  if (parts.length === 0 || parts.every((p) => !p.product_id && !p.choices.length)) {
    // No usable SKU: try the store title as one code, only if it clearly fits.
    const t = parseSegs({ ...cat.rules, separators: "" }, title).map((x) => resolveSeg(cat, x)).filter((p) => p.product_id);
    if (t.length) parts = t;
  }
  if (parts.length === 0) return { how: "none", parts: [] };
  if (parts.some((p) => !p.product_id)) return { how: parts.some((p) => p.choices.length) ? "unsure" : "none", parts };
  return { how: parts.length > 1 || parts[0].qty > 1 ? "bundle" : "code", parts };
}

// Two passes over a whole store list: qualified codes first, so the plain code
// knows which product the qualifier took.
function primeClaims(cat: Catalog, skus: string[]) {
  for (const sku of skus) {
    for (const s of parseSegs(cat.rules, sku)) {
      if (!s.q || cat.learned.has(s.key)) continue;
      const r = resolveSeg(cat, s);
      if (r.product_id) {
        if (!cat.claimed.has(s.base)) cat.claimed.set(s.base, new Set());
        cat.claimed.get(s.base)!.add(r.product_id);
      }
    }
  }
}

function savedFor(cat: Catalog, variantId: string | null, sku: string): Mapped | null {
  if (variantId && cat.map.has(variantId)) return cat.map.get(variantId)!;
  if (sku && cat.map.has(`sku:${sku.toLowerCase()}`)) return cat.map.get(`sku:${sku.toLowerCase()}`)!;
  return null;
}

function toMapped(s: Suggestion): Mapped | null {
  if (!s.parts.length || s.parts.some((p) => !p.product_id)) return null;
  if (s.parts.length === 1 && s.parts[0].qty === 1) return { product_id: s.parts[0].product_id, components: null };
  return { product_id: null, components: s.parts.map((p) => ({ product_id: p.product_id!, qty: p.qty })) };
}

function matchLine(cat: Catalog, variantId: string | null, sku: string, barcode: string, title: string): Mapped | null {
  const saved = savedFor(cat, variantId, sku);
  if (saved && (saved.product_id || saved.components?.length)) return saved;
  return toMapped(autoSuggest(cat, sku, barcode, title));
}

type LineComp = { product_id: string; per: number; qty: number; picked: number };
// Builds a line's match, keeping picking progress already made on it.
// deno-lint-ignore no-explicit-any
function applyMatch(cat: Catalog, line: any, old: any | null) {
  const qty = Number(line.qty ?? 0);
  const progress = old && (Number(old.picked ?? 0) > 0 ||
    ((old.components ?? []) as LineComp[]).some((c) => Number(c.picked ?? 0) > 0));
  if (progress) {
    // Already being picked: don't change what is being picked.
    const comps = old.components
      ? (old.components as LineComp[]).map((c) => ({ product_id: c.product_id, per: Number(c.per ?? 1), qty: Number(c.per ?? 1) * qty,
          picked: Math.min(Number(c.picked ?? 0), Number(c.per ?? 1) * qty) }))
      : null;
    return { ...line, product_id: comps ? null : (old.product_id ?? null), components: comps, picked: Math.min(Number(old.picked ?? 0), qty) };
  }
  const m = matchLine(cat, line.variant_id ?? null, String(line.sku ?? ""), String(line.barcode ?? ""), String(line.title ?? ""));
  const comps = m?.components?.length
    ? m.components.map((c) => ({ product_id: c.product_id, per: c.qty, qty: c.qty * qty, picked: 0 }))
    : null;
  return { ...line, product_id: comps ? null : (m?.product_id ?? null), components: comps, picked: 0 };
}

// deno-lint-ignore no-explicit-any
async function saveOrder(admin: SupabaseClient, store: Store, cat: Catalog, o: any) {
  const { data: prev } = await admin.from("shop_orders").select("id, status, lines")
    .eq("store_id", store.id).eq("external_id", o.id).maybeSingle();
  // deno-lint-ignore no-explicit-any
  const prevLine = new Map<string, any>();
  for (const l of (prev?.lines ?? []) as Array<Record<string, unknown>>) prevLine.set(String(l.line_id), l);
  // deno-lint-ignore no-explicit-any
  const lines = (o.lineItems?.nodes ?? []).map((li: any) => applyMatch(cat, {
    line_id: li.id, title: li.title, variant_title: li.variantTitle ?? null,
    sku: String(li.sku ?? li.variant?.sku ?? "").trim(), barcode: String(li.variant?.barcode ?? "").trim(),
    variant_id: li.variant?.id ?? null,
    qty: Number(li.currentQuantity ?? li.quantity ?? 0),
    price: Number(li.originalUnitPriceSet?.shopMoney?.amount ?? 0),
  }, prevLine.get(li.id) ?? null)).filter((l: { qty: number }) => l.qty > 0);

  // Matches can't change once an order is shipped / cancelled.
  if (prev && (prev.status === "fulfilled" || prev.status === "cancelled")) {
    for (const l of lines) {
      const old = prevLine.get(String(l.line_id));
      if (old) { l.product_id = old.product_id ?? null; l.components = old.components ?? null; l.picked = old.picked ?? 0; }
    }
  }

  let status = prev?.status ?? "new";
  if (o.cancelledAt) status = "cancelled";
  else if (o.displayFulfillmentStatus === "FULFILLED" && status !== "fulfilled") status = "fulfilled";

  const a = o.shippingAddress;
  const row = {
    org_id: store.org_id, store_id: store.id, external_id: o.id, order_no: o.name,
    placed_at: o.createdAt, ext_updated_at: o.updatedAt,
    financial_status: o.displayFinancialStatus, ext_fulfillment: o.displayFulfillmentStatus,
    payment_methods: (o.paymentGatewayNames ?? []).join(", "),
    cancelled_at: o.cancelledAt,
    customer_name: a?.name ?? o.customer?.displayName ?? null,
    email: o.email ?? o.customer?.email ?? null,
    phone: a?.phone ?? o.phone ?? o.customer?.phone ?? null,
    ship_to: a ?? null, note: o.note ?? null,
    total: Number(o.totalPriceSet?.shopMoney?.amount ?? 0),
    currency: o.totalPriceSet?.shopMoney?.currencyCode ?? null,
    lines, status, updated_at: new Date().toISOString(),
  };
  const { error } = await admin.from("shop_orders").upsert(row, { onConflict: "store_id,external_id" });
  if (error) throw new Error(error.message);
}

async function syncStore(admin: SupabaseClient, store: Store, sec: Secret, sinceIso: string | null) {
  const { data: st } = await admin.from("shop_stores").select("last_sync_at").eq("id", store.id).single();
  const since = sinceIso ?? (st?.last_sync_at
    ? new Date(Date.parse(st.last_sync_at) - 15 * 60 * 1000).toISOString()
    : new Date(Date.now() - 7 * 86400000).toISOString());
  const started = new Date().toISOString();
  const cat = await loadCatalog(admin, store);
  let after: string | null = null;
  let n = 0;
  for (let page = 0; page < 40; page++) {
    const data = await gqlOrders(admin, store, sec,
      (f) => `query($q: String, $after: String) { orders(first: 50, after: $after, sortKey: UPDATED_AT, query: $q) {
         pageInfo { hasNextPage endCursor } nodes { ${f} } } }`,
      { q: `updated_at:>='${since}'`, after });
    for (const o of data.orders.nodes) { await saveOrder(admin, store, cat, o); n++; }
    if (!data.orders.pageInfo.hasNextPage) break;
    after = data.orders.pageInfo.endCursor;
  }
  await admin.from("shop_stores").update({ last_sync_at: started, last_error: null }).eq("id", store.id);
  return n;
}

async function refreshOne(admin: SupabaseClient, store: Store, sec: Secret, gid: string) {
  const data = await gqlOrders(admin, store, sec, (f) => `query($id: ID!) { order(id: $id) { ${f} } }`, { id: gid });
  if (!data.order) return;
  await saveOrder(admin, store, await loadCatalog(admin, store), data.order);
}

async function registerWebhooks(admin: SupabaseClient, store: Store, sec: Secret): Promise<string | null> {
  const url = `${FN_URL}?store=${store.id}`;
  const problems: string[] = [];
  for (const topic of ["ORDERS_CREATE", "ORDERS_UPDATED", "ORDERS_CANCELLED"]) {
    let ok = false;
    for (const field of ["uri", "callbackUrl"]) {
      try {
        const d = await gql(admin, store, sec,
          `mutation($topic: WebhookSubscriptionTopic!, $sub: WebhookSubscriptionInput!) {
             webhookSubscriptionCreate(topic: $topic, webhookSubscription: $sub) {
               webhookSubscription { id } userErrors { message } } }`,
          { topic, sub: { [field]: url, format: "JSON" } });
        const errs = d.webhookSubscriptionCreate.userErrors ?? [];
        if (errs.length === 0 || errs.some((e: { message: string }) => /taken|already/i.test(e.message))) { ok = true; break; }
        problems.push(`${topic}: ${errs.map((e: { message: string }) => e.message).join("; ")}`);
      } catch (e) {
        if (field === "callbackUrl") problems.push(`${topic}: ${(e as Error).message}`);
      }
    }
    if (!ok && problems.length === 0) problems.push(`${topic}: not registered`);
  }
  const allOk = problems.length === 0;
  await admin.from("shop_stores").update({ webhooks_ok: allOk }).eq("id", store.id);
  return allOk ? null : problems.join(" | ");
}

async function fulfil(admin: SupabaseClient, store: Store, sec: Secret, gid: string,
    tracking: { company?: string; number?: string; url?: string }, notify: boolean) {
  const d = await gql(admin, store, sec,
    `query($id: ID!) { order(id: $id) { fulfillmentOrders(first: 20) { nodes { id status } } } }`, { id: gid });
  const open = (d.order?.fulfillmentOrders?.nodes ?? [])
    .filter((f: { status: string }) => ["OPEN", "IN_PROGRESS", "SCHEDULED"].includes(f.status));
  if (open.length === 0) return { already: true };
  const trackingInfo: Record<string, string> = {};
  if (tracking.company) trackingInfo.company = tracking.company;
  if (tracking.number) trackingInfo.number = tracking.number;
  if (tracking.url) trackingInfo.url = tracking.url;
  const input = {
    lineItemsByFulfillmentOrder: open.map((f: { id: string }) => ({ fulfillmentOrderId: f.id })),
    notifyCustomer: notify,
    ...(Object.keys(trackingInfo).length ? { trackingInfo } : {}),
  };
  for (const m of ["fulfillmentCreate", "fulfillmentCreateV2"]) {
    try {
      const r = await gql(admin, store, sec,
        `mutation($f: FulfillmentInput!) { ${m}(fulfillment: $f) { fulfillment { id status } userErrors { field message } } }`,
        { f: input });
      const errs = r[m].userErrors ?? [];
      if (errs.length) throw new Error(errs.map((e: { message: string }) => e.message).join("; "));
      return { already: false };
    } catch (e) {
      const msg = (e as Error).message;
      if (m === "fulfillmentCreate" && /doesn't exist|undefinedField|Field 'fulfillmentCreate'/i.test(msg)) continue;
      throw e;
    }
  }
  throw new Error("Shopify did not accept the fulfilment.");
}

// ── Install / authorise (for stores outside the app's organisation, or any
//    install started from Shopify) ───────────────────────────────────────────
async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)));
  return [...sig].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function authorizeUrl(store: Store, sec: Secret): Promise<string> {
  const state = `${store.id}.${(await hmacHex(sec.client_secret ?? "", store.id)).slice(0, 24)}`;
  const q = new URLSearchParams({
    client_id: sec.client_id ?? "", scope: SCOPES, redirect_uri: `${FN_URL}/oauth`, state,
  });
  return `https://${store.shop_domain}/admin/oauth/authorize?${q}`;
}

/// Shopify signs install / callback links: hex HMAC of the sorted query minus hmac.
async function queryHmacOk(secret: string, params: URLSearchParams): Promise<boolean> {
  const given = params.get("hmac") ?? "";
  const pairs = [...params.entries()].filter(([k]) => k !== "hmac" && k !== "signature")
    .sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${k}=${v}`).join("&");
  const mine = await hmacHex(secret, pairs);
  return given.length === mine.length && given.toLowerCase() === mine;
}

const page = (title: string, text: string, status = 200) => new Response(
  `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title></head>
   <body style="font-family:Segoe UI,Arial,sans-serif;background:#f4f6fa;padding:40px">
   <div style="max-width:520px;margin:auto;background:#fff;border:1px solid #e5e7eb;border-radius:14px;padding:24px">
   <h2 style="margin-top:0">${title}</h2><p>${text}</p>
   <p><a href="${APP_URL}/erp/fulfillment">Open Opstation → Fulfillment</a></p></div></body></html>`,
  { status, headers: { "Content-Type": "text/html; charset=utf-8" } });

// ── Notifications from Shopify ───────────────────────────────────────────────
async function verifyHmac(secret: string, raw: Uint8Array, header: string): Promise<boolean> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, raw));
  let bin = "";
  for (const b of sig) bin += String.fromCharCode(b);
  const mine = btoa(bin);
  if (mine.length !== header.length) return false;
  let diff = 0;
  for (let i = 0; i < mine.length; i++) diff |= mine.charCodeAt(i) ^ header.charCodeAt(i);
  return diff === 0;
}

async function loadStore(admin: SupabaseClient, id: string): Promise<[Store, Secret] | null> {
  const { data: s } = await admin.from("shop_stores").select("*").eq("id", id).maybeSingle();
  if (!s) return null;
  const { data: k } = await admin.from("shop_store_secrets").select("*").eq("store_id", id).maybeSingle();
  if (!k) return null;
  return [s as Store, k as Secret];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = new URL(req.url);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // 0) Install link / authorisation callback (browser comes back from Shopify)
  if (req.method === "GET" && url.pathname.endsWith("/install")) {
    const shop = normDomain(url.searchParams.get("shop") ?? "");
    const { data: rows } = await admin.from("shop_stores").select("*").eq("shop_domain", shop)
      .order("created_at", { ascending: false }).limit(1);
    const st = rows?.[0] as Store | undefined;
    if (!st) return page("Connect the store in Opstation first", `Open Opstation → Sales → Fulfillment → Connect store, enter ${shop || "the store"} with the app's Client ID and secret, then install again.`, 404);
    const loaded = await loadStore(admin, st.id);
    if (!loaded || !loaded[1].client_secret || !loaded[1].client_id) return page("Keys missing", "Enter the app's Client ID and secret in Opstation first.", 400);
    if (url.searchParams.get("hmac") && !(await queryHmacOk(loaded[1].client_secret!, url.searchParams))) {
      return page("Link not valid", "The Client secret saved in Opstation doesn't match this app. Reconnect the store in Opstation with the right secret.", 401);
    }
    return Response.redirect(await authorizeUrl(loaded[0], loaded[1]), 302);
  }
  if (req.method === "GET" && url.pathname.endsWith("/oauth")) {
    const p = url.searchParams;
    const [sid, sig] = (p.get("state") ?? "").split(".");
    const loaded = sid ? await loadStore(admin, sid) : null;
    if (!loaded || !loaded[1].client_secret) return page("Store not found", "Start again from Opstation → Fulfillment.", 404);
    const [store, sec] = loaded;
    const expect = (await hmacHex(sec.client_secret!, store.id)).slice(0, 24);
    if (sig !== expect || !(await queryHmacOk(sec.client_secret!, p)) || normDomain(p.get("shop") ?? "") !== store.shop_domain) {
      return page("Could not verify", "Shopify's reply could not be verified. Start again from Opstation.", 401);
    }
    const r = await fetch(`https://${store.shop_domain}/admin/oauth/access_token`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ client_id: sec.client_id, client_secret: sec.client_secret, code: p.get("code") }),
    });
    const t = await r.text();
    if (!r.ok) return page("Shopify refused", `Shopify did not give access (${r.status}). ${t.slice(0, 200)}`, 400);
    const j = JSON.parse(t);
    sec.access_token = j.access_token;
    sec.token_expires_at = j.expires_in ? new Date(Date.now() + Number(j.expires_in) * 1000).toISOString() : null;
    await admin.from("shop_store_secrets").update({ access_token: sec.access_token, token_expires_at: sec.token_expires_at }).eq("store_id", store.id);
    await admin.from("shop_stores").update({ is_active: true, last_error: null }).eq("id", store.id);
    let note = "";
    try {
      const hp = await registerWebhooks(admin, store, sec);
      const n = await syncStore(admin, store, sec, new Date(Date.now() - 7 * 86400000).toISOString());
      note = `${n} order(s) from the last 7 days brought in.${hp ? " Live updates could not be switched on; the 10-minute sync still runs." : ""}`;
    } catch (e) {
      note = `Connected, but the first sync had a problem: ${(e as Error).message}`;
    }
    return Response.redirect(`${APP_URL}/erp/fulfillment?connected=${encodeURIComponent(note)}`, 302);
  }

  // 1) Shopify notification
  const hmac = req.headers.get("X-Shopify-Hmac-Sha256");
  if (hmac) {
    const raw = new Uint8Array(await req.arrayBuffer());
    const sid = url.searchParams.get("store") ?? "";
    const loaded = await loadStore(admin, sid);
    if (!loaded || !loaded[1].client_secret) return new Response("unknown store", { status: 401 });
    const [store, sec] = loaded;
    if (!(await verifyHmac(sec.client_secret!, raw, hmac))) return new Response("bad signature", { status: 401 });
    try {
      const body = JSON.parse(new TextDecoder().decode(raw));
      const gid = body.admin_graphql_api_id ?? (body.id ? `gid://shopify/Order/${body.id}` : null);
      if (gid && store.is_active) await refreshOne(admin, store, sec, gid);
    } catch (e) {
      await admin.from("shop_stores").update({ last_error: `Notification: ${(e as Error).message}`.slice(0, 500) }).eq("id", store.id);
    }
    return new Response("ok"); // always 200 so Shopify doesn't retry forever
  }

  // deno-lint-ignore no-explicit-any
  let body: any = {};
  try { body = await req.json(); } catch { /* none */ }
  const action = String(body.action ?? "");
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const claims = jwtPayload(token);

  // 2) Scheduled sync (service key)
  if (action === "sync_all") {
    if (claims?.role !== "service_role") return json({ error: "not allowed" }, 403);
    const { data: stores } = await admin.from("shop_stores").select("id").eq("is_active", true);
    const out: Record<string, unknown> = {};
    for (const s of stores ?? []) {
      const loaded = await loadStore(admin, s.id);
      if (!loaded) continue;
      try { out[s.id] = await syncStore(admin, loaded[0], loaded[1], null); }
      catch (e) {
        out[s.id] = (e as Error).message;
        await admin.from("shop_stores").update({ last_error: (e as Error).message.slice(0, 500) }).eq("id", s.id);
      }
    }
    return json({ ok: true, synced: out });
  }

  // 3) Signed-in user
  const { data: u } = await admin.auth.getUser(token);
  const email = u?.user?.email;
  if (!email) return json({ error: "Please sign in again." }, 401);
  const { data: me } = await admin.from("users").select("id, name, org_id, role, is_active").ilike("email", email).limit(5);
  const meRows = (me ?? []).filter((r: { is_active: boolean | null }) => r.is_active !== false);
  const isAdminRole = (r: string) => ["admin", "masterAdmin", "superAdmin"].includes(r);
  const userFor = (org: string) => meRows.find((r: { org_id: string; role: string }) => r.org_id === org || r.role === "superAdmin");

  try {
    if (action === "connect") {
      const org = String(body.org_id ?? "");
      const mine = userFor(org);
      if (!mine || !isAdminRole(mine.role)) return json({ error: "Only an admin can connect a store." }, 403);
      const shop = normDomain(String(body.shop_domain ?? ""));
      if (!shop.endsWith(".myshopify.com")) return json({ error: "Enter the store's .myshopify.com address." }, 400);
      if (!body.client_secret) return json({ error: "The app's client secret is required." }, 400);
      if (!body.access_token && !body.client_id) return json({ error: "Enter the client ID (or an Admin API access token)." }, 400);

      const { data: existing } = await admin.from("shop_stores").select("*").eq("org_id", org).eq("shop_domain", shop).maybeSingle();
      let store: Store;
      if (existing) {
        await admin.from("shop_stores").update({
          name: body.name ?? existing.name, branch_id: body.branch_id ?? existing.branch_id, is_active: true,
        }).eq("id", existing.id);
        store = { ...existing, name: body.name ?? existing.name, branch_id: body.branch_id ?? existing.branch_id, is_active: true };
      } else {
        const { data: ins, error } = await admin.from("shop_stores").insert({
          org_id: org, shop_domain: shop, name: body.name || shop.replace(".myshopify.com", ""), branch_id: body.branch_id ?? null,
        }).select("*").single();
        if (error) throw new Error(error.message);
        store = ins as Store;
      }
      const sec: Secret = {
        store_id: store.id, client_id: body.client_id || null, client_secret: body.client_secret,
        access_token: body.access_token || null, token_expires_at: null,
      };
      await admin.from("shop_store_secrets").upsert(sec, { onConflict: "store_id" });
      // Test the key, then subscribe to order notifications and pull recent orders.
      // deno-lint-ignore no-explicit-any
      let shopInfo: any;
      try {
        shopInfo = await gql(admin, store, sec, `{ shop { name } }`);
      } catch (e) {
        // Keys saved, but no access yet (app not installed, or the store is not
        // in the app's organisation): finish by authorising in Shopify.
        if (sec.client_id) {
          return json({ ok: true, pending: true, store_id: store.id, authorize_url: await authorizeUrl(store, sec),
            reason: (e as Error).message.slice(0, 300) });
        }
        throw e;
      }
      if (!existing && !body.name && shopInfo?.shop?.name) {
        await admin.from("shop_stores").update({ name: shopInfo.shop.name }).eq("id", store.id);
      }
      const hookProblem = await registerWebhooks(admin, store, sec);
      const days = Math.max(1, Math.min(90, Number(body.days ?? 7)));
      const n = await syncStore(admin, store, sec, new Date(Date.now() - days * 86400000).toISOString());
      return json({ ok: true, store_id: store.id, shop: shopInfo?.shop?.name, imported: n, webhook_warning: hookProblem });
    }

    // Everything else acts on a store / order the user's org owns.
    let store: Store, sec: Secret;
    // deno-lint-ignore no-explicit-any
    let order: any = null;
    if (body.order_id) {
      const { data: o } = await admin.from("shop_orders").select("*").eq("id", body.order_id).maybeSingle();
      if (!o) return json({ error: "Order not found." }, 404);
      order = o;
      const l = await loadStore(admin, o.store_id);
      if (!l) return json({ error: "Store not connected." }, 404);
      [store, sec] = l;
    } else {
      const l = await loadStore(admin, String(body.store_id ?? ""));
      if (!l) return json({ error: "Store not found." }, 404);
      [store, sec] = l;
    }
    const mine = userFor(store.org_id);
    if (!mine) return json({ error: "Not allowed." }, 403);

    if (action === "sync") {
      const n = await syncStore(admin, store, sec, body.days ? new Date(Date.now() - Number(body.days) * 86400000).toISOString() : null);
      const hookProblem = (await admin.from("shop_stores").select("webhooks_ok").eq("id", store.id).single()).data?.webhooks_ok
        ? null : await registerWebhooks(admin, store, sec);
      return json({ ok: true, synced: n, webhook_warning: hookProblem });
    }
    if (action === "refresh_order") {
      await refreshOne(admin, store, sec, order.external_id);
      return json({ ok: true });
    }
    if (action === "fulfill") {
      if (order.status === "cancelled") return json({ error: "This order was cancelled." }, 400);
      // Only ship what was actually picked: every item scanned in full first.
      const short = ((order.lines ?? []) as Array<Record<string, unknown>>).filter((l) => {
        const comps = l.components as Array<Record<string, unknown>> | null;
        if (comps && comps.length) return comps.some((c) => Number(c.picked ?? 0) < Number(c.qty ?? 0));
        return Number(l.picked ?? 0) < Number(l.qty ?? 0);
      });
      if (short.length > 0) {
        return json({ error: `Pick every item first — ${short.length} item(s) not fully picked.` }, 400);
      }
      const r = await fulfil(admin, store, sec, order.external_id,
        { company: body.company, number: body.number, url: body.url }, body.notify !== false);
      await admin.from("shop_orders").update({
        status: "fulfilled", fulfilled_at: new Date().toISOString(), fulfilled_by_name: mine.name ?? null,
        tracking_company: body.company ?? null, tracking_number: body.number ?? null, tracking_url: body.url ?? null,
        fulfil_error: null, updated_at: new Date().toISOString(),
      }).eq("id", order.id);
      return json({ ok: true, already: r.already });
    }
    if (action === "granted_scopes") {
      // What the store has actually approved for this connection.
      const d = await gql(admin, store, sec, `{ currentAppInstallation { accessScopes { handle } } }`);
      return json({ ok: true, scopes: (d.currentAppInstallation?.accessScopes ?? []).map((x: { handle: string }) => x.handle) });
    }
    if (action === "list_variants") {
      // Every product variant in the store, for bulk matching to Opstation products.
      const out: Array<Record<string, unknown>> = [];
      let after: string | null = null;
      for (let page = 0; page < 30; page++) {
        const d = await gql(admin, store, sec,
          `query($after: String) { productVariants(first: 250, after: $after) {
             pageInfo { hasNextPage endCursor }
             nodes { id title sku barcode product { title status } } } }`, { after });
        for (const v of d.productVariants.nodes) {
          out.push({ id: v.id, product: v.product?.title ?? "", variant: v.title ?? "", sku: v.sku ?? "",
            barcode: v.barcode ?? "", status: v.product?.status ?? "" });
        }
        if (!d.productVariants.pageInfo.hasNextPage) break;
        after = d.productVariants.pageInfo.endCursor;
      }
      // Suggestions from the item codes (finished products only) + any saved choice.
      const cat = await loadCatalog(admin, store);
      primeClaims(cat, out.map((v) => String(v.sku ?? "")));
      for (const v of out) {
        const sku = String(v.sku ?? "").trim();
        const auto = autoSuggest(cat, sku, String(v.barcode ?? "").trim(), String(v.product ?? ""));
        const saved = savedFor(cat, String(v.id), sku);
        v.auto = auto;
        v.saved = saved && (saved.product_id || saved.components?.length)
          ? (saved.components?.length ? saved.components : [{ product_id: saved.product_id, qty: 1 }])
          : null;
      }
      return json({ ok: true, variants: out, groups: cat.groups, all_groups: cat.allGroups });
    }
    if (action === "test_sku") {
      // Try SKU rules (saved or not) on sample SKUs: how each one is read.
      const cat = await loadCatalog(admin, store);
      if (body.rules) cat.rules = rulesOf(body.rules);
      const ids = new Set<string>();
      const out = ((body.skus ?? []) as string[]).slice(0, 20).map((sku) => {
        const segs = parseSegs(cat.rules, String(sku ?? ""));
        const parts = segs.map((x) => { const r = resolveSeg(cat, x); [r.product_id, ...r.choices].forEach((i) => i && ids.add(i)); return r; });
        return { sku, parts };
      });
      const names: Record<string, string> = {};
      if (ids.size) {
        const { data } = await admin.from("products").select("id, name").in("id", [...ids]);
        for (const p of data ?? []) names[p.id] = p.name;
      }
      return json({ ok: true, results: out, names, rules: cat.rules });
    }
    if (action === "rematch") {
      // Re-apply saved / code matches to open orders not yet being picked.
      const cat = await loadCatalog(admin, store);
      const { data: open } = await admin.from("shop_orders").select("id, lines")
        .eq("store_id", store.id).in("status", ["new", "picking", "packed"]);
      let changed = 0;
      for (const o of open ?? []) {
        const before = JSON.stringify(o.lines ?? []);
        // deno-lint-ignore no-explicit-any
        const lines = ((o.lines ?? []) as any[]).map((l) => applyMatch(cat, l, l));
        if (JSON.stringify(lines) !== before) {
          await admin.from("shop_orders").update({ lines, updated_at: new Date().toISOString() }).eq("id", o.id);
          changed++;
        }
      }
      return json({ ok: true, orders: changed });
    }
    if (action === "authorize_url") {
      if (!isAdminRole(mine.role)) return json({ error: "Only an admin can do this." }, 403);
      if (!sec.client_id) return json({ error: "This store was connected with an access token — reconnect it with the Client ID instead." }, 400);
      return json({ ok: true, authorize_url: await authorizeUrl(store, sec) });
    }
    if (action === "disconnect") {
      if (!isAdminRole(mine.role)) return json({ error: "Only an admin can disconnect a store." }, 403);
      await admin.from("shop_stores").update({ is_active: false, webhooks_ok: false }).eq("id", store.id);
      await admin.from("shop_store_secrets").update({ access_token: null, token_expires_at: null }).eq("store_id", store.id);
      return json({ ok: true });
    }
    return json({ error: "Unknown action." }, 400);
  } catch (e) {
    const msg = (e as Error).message;
    if (body.order_id && action === "fulfill") {
      await admin.from("shop_orders").update({ fulfil_error: msg.slice(0, 500) }).eq("id", body.order_id);
    }
    return json({ error: msg }, 400);
  }
});
