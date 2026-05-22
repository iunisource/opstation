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
}

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
    if (!isSuperAdmin && !isMasterAdmin) return json({ error: 'forbidden' }, 403)

    let p: Payload
    try { p = await req.json() } catch { return json({ error: 'bad_json' }, 400) }
    if (!p.name || !p.email || !p.password || !p.role || !p.orgId)
      return json({ error: 'missing_fields' }, 400)
    if (p.password.length < 6) return json({ error: 'weak_password' }, 400)

    // masterAdmin can only create users in their own org
    if (isMasterAdmin && callerRow?.org_id !== p.orgId)
      return json({ error: 'forbidden' }, 403)

    // Check email uniqueness
    const { data: existing } = await admin.from('users').select('id').ilike('email', p.email).limit(1)
    if ((existing ?? []).length > 0) return json({ error: 'email_exists' }, 409)

    // Create auth user
    const { data: authData, error: authErr } = await admin.auth.admin.createUser({
      email: p.email,
      password: p.password,
      email_confirm: true,
    })
    if (authErr || !authData?.user) return json({ error: 'auth_create_failed', detail: authErr?.message }, 500)

    const authUserId = authData.user.id
    const userId = `user_${Date.now()}`

    try {
      const { error: userErr } = await admin.from('users').insert({
        id: userId,
        name: p.name,
        email: p.email,
        phone: '',
        role: p.role,
        is_active: true,
        password_hash: '',
        password_salt: '',
        password_temporary: true,
        org_id: p.orgId,
        created_at: new Date().toISOString(),
      })
      if (userErr) throw new Error(userErr.message)
      return json({ userId, authUserId })
    } catch (e) {
      await admin.auth.admin.deleteUser(authUserId).catch(() => {})
      return json({ error: 'insert_failed', detail: e instanceof Error ? e.message : String(e) }, 500)
    }
  } catch (e) {
    return json({ error: 'unhandled', detail: e instanceof Error ? e.message : String(e) }, 500)
  }
})
