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
  name: string
  email: string
  password: string
  role: string
  orgId: string
  phone?: string
}

// Roles an org admin (not master/super) is allowed to create — the mobile
// "app user" roles. Admins cannot mint other admins/masters/supers here.
const ADMIN_CREATABLE_ROLES = [
  'salesperson', 'driver', 'surveyor', 'dispatchManager', 'accountant',
]

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)

  try {
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)

    // Verify caller is masterAdmin or superAdmin
    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
    if (!token) return json({ error: 'missing_auth' }, 401)
    const { data: callerAuth, error: callerErr } = await admin.auth.getUser(token)
    if (callerErr || !callerAuth?.user?.email) return json({ error: 'invalid_auth' }, 401)

    const { data: callerRow } = await admin
      .from('users').select('role, org_id')
      .ilike('email', callerAuth.user.email).maybeSingle()

    const isSuperAdmin = callerRow?.role === 'superAdmin'
    const isMasterAdmin = callerRow?.role === 'masterAdmin'
    const isAdmin = callerRow?.role === 'admin'
    if (!isSuperAdmin && !isMasterAdmin && !isAdmin) return json({ error: 'forbidden' }, 403)

    let p: Payload
    try { p = await req.json() } catch { return json({ error: 'bad_json' }, 400) }
    if (!p.name || !p.email || !p.password || !p.role || !p.orgId)
      return json({ error: 'missing_fields' }, 400)
    if (p.password.length < 6) return json({ error: 'weak_password' }, 400)

    // admin and masterAdmin can only create users in their own org
    if ((isMasterAdmin || isAdmin) && callerRow?.org_id !== p.orgId)
      return json({ error: 'forbidden' }, 403)

    // Nobody mints a superAdmin through this endpoint; org admins are further
    // limited to the mobile "app user" roles (no admin/master/erpUser).
    if (p.role === 'superAdmin') return json({ error: 'forbidden_role' }, 403)
    if (isAdmin && !ADMIN_CREATABLE_ROLES.includes(p.role))
      return json({ error: 'forbidden_role' }, 403)

    // Check email uniqueness
    const { data: existing } = await admin.from('users').select('id').ilike('email', p.email).limit(1)
    if ((existing ?? []).length > 0) return json({ error: 'email_exists' }, 409)

    // Create the auth user. If an auth account for this email already exists
    // (typically a member who was deleted from `users` — Team's Delete leaves
    // the auth row behind), reuse it and set the new password instead of
    // failing, so the email stays re-usable.
    let authUserId: string
    let reusedAuth = false
    const { data: authData, error: authErr } = await admin.auth.admin.createUser({
      email: p.email,
      password: p.password,
      email_confirm: true,
    })
    if (authData?.user) {
      authUserId = authData.user.id
    } else {
      const { data: existingAuthId } = await admin.rpc('auth_id_for_email', { p_email: p.email })
      if (!existingAuthId) {
        return json({ error: 'auth_create_failed', detail: authErr?.message }, 500)
      }
      const { error: updErr } = await admin.auth.admin.updateUserById(existingAuthId as string, {
        password: p.password,
        email_confirm: true,
      })
      if (updErr) return json({ error: 'auth_update_failed', detail: updErr.message }, 500)
      authUserId = existingAuthId as string
      reusedAuth = true
    }

    const userId = `user_${Date.now()}`

    try {
      const { error: userErr } = await admin.from('users').insert({
        id: userId,
        name: p.name,
        email: p.email,
        phone: (p.phone ?? '').toString().trim(),
        role: p.role,
        is_active: true,
        password_hash: '',
        password_salt: '',
        password_temporary: true,
        org_id: p.orgId,
        created_at: new Date().toISOString(),
      })
      if (userErr) throw new Error(userErr.message)
      return json({ userId, authUserId, reusedAuth })
    } catch (e) {
      // Only roll back an auth account we created in this call — never
      // delete a pre-existing one we reused.
      if (!reusedAuth) await admin.auth.admin.deleteUser(authUserId).catch(() => {})
      return json({ error: 'insert_failed', detail: e instanceof Error ? e.message : String(e) }, 500)
    }
  } catch (e) {
    return json({ error: 'unhandled', detail: e instanceof Error ? e.message : String(e) }, 500)
  }
})
