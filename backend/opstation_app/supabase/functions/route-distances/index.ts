// route-distances — road distance (km) for each leg of a trip, from Google
// Directions. Used by trip reports on the web and in the app.
//
//   POST { orgId: string, points: [[lat, lng], ...] }   (signed-in user)
//   → { legs: number[] | null, cached: boolean, reason?: string }
//
// Google takes at most 25 points per request, so longer trips are asked in
// pieces that share their joining points. Results are saved per organisation
// under the trip's exact points (update 422), so the same trip is paid for
// once. A daily cap per organisation applies. Any failure returns legs: null
// and the caller uses straight-line distances — reports never break.
//
// Deploy:  supabase functions deploy route-distances --project-ref <ref>
// Secret:  supabase secrets set GOOGLE_MAPS_API_KEY=<key> --project-ref <ref>

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!
const GOOGLE_KEY = Deno.env.get('GOOGLE_MAPS_API_KEY') ?? ''
const MAX_POINTS = 25
const MAX_TOTAL_POINTS = 400

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('')
}

async function legsOneCall(pts: [number, number][]): Promise<number[] | null> {
  const p = (x: [number, number]) => `${x[0]},${x[1]}`
  const params = new URLSearchParams({
    origin: p(pts[0]),
    destination: p(pts[pts.length - 1]),
    key: GOOGLE_KEY,
  })
  if (pts.length > 2) params.set('waypoints', pts.slice(1, -1).map(p).join('|'))
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), 12000)
  try {
    const r = await fetch(`https://maps.googleapis.com/maps/api/directions/json?${params}`, { signal: ctrl.signal })
    if (!r.ok) return null
    const j = await r.json()
    if (j.status !== 'OK') return null
    const legs = j.routes?.[0]?.legs
    if (!Array.isArray(legs) || legs.length !== pts.length - 1) return null
    const out: number[] = []
    for (const l of legs) {
      const m = l?.distance?.value
      if (typeof m !== 'number') return null
      out.push(m / 1000)
    }
    return out
  } catch (_) {
    return null
  } finally {
    clearTimeout(t)
  }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ legs: null, reason: 'method' }, 405)
  try {
    const auth = req.headers.get('Authorization') ?? ''
    if (!auth) return json({ legs: null, reason: 'auth' }, 401)
    let body: any
    try { body = await req.json() } catch { return json({ legs: null, reason: 'bad_json' }, 400) }
    const orgId = String(body?.orgId ?? '')
    const raw = Array.isArray(body?.points) ? body.points : []
    const pts: [number, number][] = []
    for (const x of raw) {
      const lat = Number(x?.[0]), lng = Number(x?.[1])
      if (!isFinite(lat) || !isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
        return json({ legs: null, reason: 'bad_point' }, 400)
      }
      pts.push([Math.round(lat * 1e5) / 1e5, Math.round(lng * 1e5) / 1e5])
    }
    if (!orgId || pts.length < 2) return json({ legs: null, reason: 'too_few_points' })
    if (pts.length > MAX_TOTAL_POINTS) return json({ legs: null, reason: 'too_many_points' })

    // Acts as the signed-in user: the database checks organisation membership.
    const db = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: auth } } })
    const key = await sha256(pts.map((x) => `${x[0]},${x[1]}`).join(';'))

    const cached = await db.rpc('route_distance_cached', { p_org: orgId, p_key: key })
    if (cached.error) return json({ legs: null, reason: 'access' }, 403)
    if (Array.isArray(cached.data) && cached.data.length === pts.length - 1) {
      return json({ legs: cached.data, cached: true })
    }

    if (!GOOGLE_KEY) return json({ legs: null, reason: 'no_key' })
    const calls = Math.ceil((pts.length - 1) / (MAX_POINTS - 1))
    const ok = await db.rpc('route_distance_reserve', { p_org: orgId, p_calls: calls })
    if (ok.error || ok.data !== true) return json({ legs: null, reason: 'daily_limit' })

    const legs: number[] = []
    for (let i = 0; i < pts.length - 1; i += MAX_POINTS - 1) {
      const end = Math.min(i + MAX_POINTS - 1, pts.length - 1)
      const part = await legsOneCall(pts.slice(i, end + 1))
      if (!part) return json({ legs: null, reason: 'google_failed' })
      legs.push(...part)
    }
    if (legs.length !== pts.length - 1) return json({ legs: null, reason: 'google_failed' })

    await db.rpc('route_distance_save', { p_org: orgId, p_key: key, p_legs: legs, p_calls: calls })
    return json({ legs, cached: false })
  } catch (e) {
    return json({ legs: null, reason: 'error' })
  }
})
