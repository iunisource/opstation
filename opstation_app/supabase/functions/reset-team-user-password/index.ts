import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

interface Payload {
  email: string
  newPassword: string
}

// Mirrors the app's canEditTargetUser() permission model so the server is the
// real authority (the client check is only UX). callerOrg/targetOrg are the
// org_id strings from public.users.
function canReset(
  callerRole: string,
  callerOrg: string | null,
  targetRole: string,
  targetOrg: string | null,
): boolean {
  if (callerRole === 'superAdmin') return true
  if (callerRole === 'masterAdmin') {
    return targetRole !== 'superAdmin' && callerOrg != null && callerOrg === targetOrg
  }
  if (callerRole === 'admin') {
    const blocked =
      targetRole === 'superAdmin' || targetRole === 'masterAdmin' || targetRole === 'admin'
    return !blocked && callerOrg != null && callerOrg === targetOrg
  }
  return false
}


// Caller's role IN a given org. A login can belong to several orgs (users rows
// linked by account_id), each with its own role; an email-only lookup picked an
// arbitrary membership (or failed when there were several).
async function callerRoleInOrg(admin: any, email: string, orgId: string | null) {
  const { data: rows } = await admin
    .from('users').select('id, role, org_id, account_id, is_active')
    .ilike('email', email).limit(5)
  const list = (rows ?? []) as any[]
  if (list.some((r) => r.role === 'superAdmin')) return { role: 'superAdmin', org_id: orgId }
  const accountId = list[0]?.account_id ?? list[0]?.id
  if (accountId && orgId) {
    const { data: mem } = await admin
      .from('users').select('role, org_id, is_active')
      .eq('account_id', accountId).eq('org_id', orgId).limit(1)
    const m = (mem ?? [])[0]
    if (m && m.is_active !== false) return { role: m.role as string, org_id: m.org_id as string }
  }
  const same = list.find((r) => r.org_id === orgId && r.is_active !== false)
  return same ? { role: same.role as string, org_id: same.org_id as string } : null
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)

  try {
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)

    // --- Authenticate the caller from their bearer token ---
    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
    if (!token) return json({ error: 'missing_auth' }, 401)
    const { data: callerAuth, error: callerErr } = await admin.auth.getUser(token)
    if (callerErr || !callerAuth?.user?.email) return json({ error: 'invalid_auth' }, 401)

    // --- Validate payload ---
    let p: Payload
    try { p = await req.json() } catch { return json({ error: 'bad_json' }, 400) }
    if (!p.email || !p.newPassword) return json({ error: 'missing_fields' }, 400)
    if (p.newPassword.length < 6) return json({ error: 'weak_password' }, 400)

    // --- Load target & authorize ---
    const { data: targetRow } = await admin
      .from('users').select('role, org_id')
      .ilike('email', p.email).maybeSingle()
    if (!targetRow?.role) return json({ error: 'user_not_found' }, 404)

    const callerRow = await callerRoleInOrg(admin, callerAuth.user.email, targetRow.org_id ?? null)
    if (!callerRow?.role) return json({ error: 'forbidden' }, 403)

    if (!canReset(callerRow.role, callerRow.org_id ?? null, targetRow.role, targetRow.org_id ?? null)) {
      return json({ error: 'forbidden' }, 403)
    }

    // --- Resolve the target's auth.users UUID by email ---
    const { data: authId, error: rpcErr } = await admin.rpc('auth_id_for_email', { p_email: p.email })
    if (rpcErr) return json({ error: 'lookup_failed', detail: rpcErr.message }, 500)

    // --- Update (or self-heal: create) the Auth credential ---
    if (authId) {
      const { error: updErr } = await admin.auth.admin.updateUserById(authId as string, {
        password: p.newPassword,
        email_confirm: true,
      })
      if (updErr) return json({ error: 'auth_update_failed', detail: updErr.message }, 500)
      return json({ ok: true, authUserId: authId, action: 'updated' })
    }

    // No auth.users row for this email (shouldn't normally happen). Create one
    // so the user can actually sign in instead of silently failing.
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email: p.email,
      password: p.newPassword,
      email_confirm: true,
    })
    if (createErr || !created?.user) {
      return json({ error: 'auth_create_failed', detail: createErr?.message }, 500)
    }
    return json({ ok: true, authUserId: created.user.id, action: 'created' })
  } catch (e) {
    return json({ error: 'unhandled', detail: e instanceof Error ? e.message : String(e) }, 500)
  }
})
