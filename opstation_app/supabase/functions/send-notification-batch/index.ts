import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const FCM_SERVICE_ACCOUNT = Deno.env.get('FCM_SERVICE_ACCOUNT')!

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const jsonHeaders = {
  ...corsHeaders,
  'Content-Type': 'application/json',
}

// Get OAuth2 access token using service account (identical to send-notification)
async function getAccessToken(serviceAccount: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const header = { alg: 'RS256', typ: 'JWT' }
  const payload = {
    iss: serviceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }
  const encode = (obj: any) =>
    btoa(JSON.stringify(obj)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')
  const signingInput = `${encode(header)}.${encode(payload)}`
  const pemKey = serviceAccount.private_key
  const pemBody = pemKey.replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\n/g, '')
  const keyData = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0))
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    keyData.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign']
  )
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    new TextEncoder().encode(signingInput)
  )
  const sig = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')
  const jwt = `${signingInput}.${sig}`
  const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  })
  const tokenData = await tokenRes.json()
  return tokenData.access_token
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  try {
    // data is an optional map of EXTRA string fields (notification_id, image_url, link_url, ...)
    const { recipient_user_ids, title, body, data } = await req.json()

    if (!Array.isArray(recipient_user_ids) || recipient_user_ids.length === 0) {
      return new Response(JSON.stringify({ sent: 0, failed: 0, note: 'no recipients' }), {
        status: 200, headers: jsonHeaders,
      })
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)

    // fetch tokens for all recipients in one query
    const { data: users } = await supabase
      .from('users')
      .select('id, fcm_token')
      .in('id', recipient_user_ids)

    const tokens = (users ?? [])
      .map((u: any) => u.fcm_token)
      .filter((t: any) => !!t)

    if (tokens.length === 0) {
      return new Response(JSON.stringify({ sent: 0, failed: 0, note: 'no fcm tokens' }), {
        status: 200, headers: jsonHeaders,
      })
    }

    const serviceAccount = JSON.parse(FCM_SERVICE_ACCOUNT)
    const accessToken = await getAccessToken(serviceAccount)
    const projectId = serviceAccount.project_id

    // FCM data fields must be strings
    const stringData: Record<string, string> = {}
    if (data && typeof data === 'object') {
      for (const k of Object.keys(data)) {
        if (data[k] !== null && data[k] !== undefined) stringData[k] = String(data[k])
      }
    }

    let sent = 0
    let failed = 0
    const chunkSize = 25
    for (let i = 0; i < tokens.length; i += chunkSize) {
      const chunk = tokens.slice(i, i + chunkSize)
      const results = await Promise.all(chunk.map(async (token: string) => {
        try {
          const res = await fetch(
            `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
            {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${accessToken}`,
              },
              body: JSON.stringify({
                message: {
                  token,
                  notification: { title, body },
                  data: stringData,
                  android: {
                    priority: 'high',
                    notification: { sound: 'default' },
                  },
                },
              }),
            }
          )
          return res.ok
        } catch (_) {
          return false
        }
      }))
      for (const ok of results) ok ? sent++ : failed++
    }

    return new Response(JSON.stringify({ sent, failed, tokens: tokens.length }), {
      status: 200, headers: jsonHeaders,
    })
  } catch (e) {
    return new Response(JSON.stringify({ error: e.message }), { status: 500, headers: jsonHeaders })
  }
})
