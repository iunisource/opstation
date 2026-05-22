import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

interface Payload {
  orgName: string
  maxUsers: number | null
  expiresAt: string | null
  maName: string
  maEmail: string
  maPassword: string
  maPasswordHash: string
  maPasswordSalt: string
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (req.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405)
  }

  try {
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)

    // 1. Verify caller is superAdmin
    const authHeader = req.headers.get('Authorization') ?? ''
    const token = authHeader.replace(/^Bearer\s+/i, '')
    if (!token) return json({ error: 'missing_auth' }, 401)

    const { data: callerAuth, error: callerErr } = await admin.auth.getUser(token)
    if (callerErr || !callerAuth?.user?.email) {
      return json({ error: 'invalid_auth', detail: callerErr?.message }, 401)
    }

    const { data: callerRow } = await admin
      .from('users')
      .select('role')
      .ilike('email', callerAuth.user.email)
      .maybeSingle()

    if (callerRow?.role !== 'superAdmin') {
      return json({ error: 'forbidden', detail: 'superAdmin role required' }, 403)
    }

    // 2. Parse payload
    let p: Payload
    try {
      p = await req.json()
    } catch {
      return json({ error: 'bad_json' }, 400)
    }
    if (!p.orgName || !p.maName || !p.maEmail || !p.maPassword ||
        !p.maPasswordHash || !p.maPasswordSalt) {
      return json({ error: 'missing_fields' }, 400)
    }
    if (p.maPassword.length < 6) {
      return json({ error: 'weak_password' }, 400)
    }

    // 3. Pre-check email uniqueness in public.users
    const { data: existingPublic } = await admin
      .from('users')
      .select('id')
      .ilike('email', p.maEmail)
      .limit(1)
    if ((existingPublic ?? []).length > 0) {
      return json({ error: 'email_exists_public' }, 409)
    }

    // 4. Create auth user (this also enforces auth.users email uniqueness)
    const { data: authData, error: authCreateErr } = await admin.auth.admin.createUser({
      email: p.maEmail,
      password: p.maPassword,
      email_confirm: true,
    })
    if (authCreateErr || !authData?.user) {
      return json({
        error: 'auth_create_failed',
        detail: authCreateErr?.message ?? 'unknown',
      }, 500)
    }
    const authUserId = authData.user.id

    // 5. Insert public.orgs + public.users with manual rollback on failure
    const now = new Date()
    const orgId = `org_${now.getTime()}`
    const maId = `user_${now.getTime()}`

    try {
      const { error: orgErr } = await admin.from('orgs').insert({
        id: orgId,
        name: p.orgName,
        is_active: true,
        max_users: p.maxUsers,
        expires_at: p.expiresAt,
        created_at: now.toISOString(),
      })
      if (orgErr) throw new Error(`orgs insert: ${orgErr.message}`)

      const { error: userErr } = await admin.from('users').insert({
        id: maId,
        name: p.maName,
        email: p.maEmail,
        phone: '',
        role: 'masterAdmin',
        is_active: true,
        password_hash: p.maPasswordHash,
        password_salt: p.maPasswordSalt,
        password_temporary: false,
        org_id: orgId,
        created_at: now.toISOString(),
      })
      if (userErr) throw new Error(`users insert: ${userErr.message}`)

      const { error: linkErr } = await admin.from('orgs').update({
        master_admin_id: maId,
        updated_at: now.toISOString(),
      }).eq('id', orgId)
      if (linkErr) throw new Error(`orgs link: ${linkErr.message}`)

      return json({ orgId, userId: maId, authUserId })
    } catch (e) {
      // Rollback: delete inserted public rows, then auth user
      await admin.from('users').delete().eq('id', maId)
      await admin.from('orgs').delete().eq('id', orgId)
      await admin.auth.admin.deleteUser(authUserId).catch(() => {})
      const msg = e instanceof Error ? e.message : String(e)
      return json({ error: 'insert_failed_rolled_back', detail: msg }, 500)
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    return json({ error: 'unhandled', detail: msg }, 500)
  }
})
