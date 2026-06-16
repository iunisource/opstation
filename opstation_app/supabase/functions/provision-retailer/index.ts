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

// Internal, non-deliverable domain. Retailers log in with code + password;
// the portal maps (code, org) -> this email behind the scenes.
const RETAILER_EMAIL_DOMAIN = 'retailers.opstation.app'
const norm = (s: string) => (s || '').toLowerCase().replace(/[^a-z0-9]/g, '')

interface Payload {
  customerId: string
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)
  try {
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)

    // Verify caller is masterAdmin or superAdmin (same as create-team-user)
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
    if (!p.customerId) return json({ error: 'missing_fields' }, 400)

    // Load the customer this login attaches to
    const { data: customer } = await admin
      .from('customers')
      .select('id, code, shop_name, phone, org_id')
      .eq('id', p.customerId)
      .maybeSingle()
    if (!customer) return json({ error: 'customer_not_found' }, 404)
    if (!customer.code) return json({ error: 'customer_has_no_code' }, 400)

    // masterAdmin can only provision within their own org
    if (isMasterAdmin && callerRow?.org_id !== customer.org_id)
      return json({ error: 'forbidden' }, 403)

    // Already provisioned?
    const { data: existingRetailer } = await admin
      .from('users').select('id')
      .eq('customer_id', customer.id).eq('role', 'retailer').limit(1)
    if ((existingRetailer ?? []).length > 0)
      return json({ error: 'already_provisioned' }, 409)

    // Deterministic synthetic email (unique across orgs) + default password = code
    const email = `${norm(customer.code)}.${norm(customer.org_id)}@${RETAILER_EMAIL_DOMAIN}`
    const code = String(customer.code)
    const tempPassword = code.length >= 6 ? code : (code + '000000').slice(0, 6)

    // Guard against a stray existing auth user / users row on this email
    const { data: emailTaken } = await admin.from('users').select('id').ilike('email', email).limit(1)
    if ((emailTaken ?? []).length > 0) return json({ error: 'email_exists' }, 409)

    // Create the auth user
    const { data: authData, error: authErr } = await admin.auth.admin.createUser({
      email,
      password: tempPassword,
      email_confirm: true,
    })
    if (authErr || !authData?.user)
      return json({ error: 'auth_create_failed', detail: authErr?.message }, 500)
    const authUserId = authData.user.id

    // Insert the linked users row (mirrors create-team-user shape + retailer fields)
    const userId = `user_${Date.now()}`
    try {
      const { error: userErr } = await admin.from('users').insert({
        id: userId,
        name: customer.shop_name || code,
        email,
        phone: customer.phone ?? '',
        role: 'retailer',
        is_active: true,
        password_hash: '',
        password_salt: '',
        password_temporary: true,
        org_id: customer.org_id,
        customer_id: customer.id,
        created_at: new Date().toISOString(),
      })
      if (userErr) throw new Error(userErr.message)
      // Return the temp password so the admin can hand it to the retailer.
      return json({ userId, authUserId, loginCode: code, email, tempPassword })
    } catch (e) {
      await admin.auth.admin.deleteUser(authUserId).catch(() => {})
      return json({ error: 'insert_failed', detail: e instanceof Error ? e.message : String(e) }, 500)
    }
  } catch (e) {
    return json({ error: 'unhandled', detail: e instanceof Error ? e.message : String(e) }, 500)
  }
})
