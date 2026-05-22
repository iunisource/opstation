import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

serve(async (_req) => {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)
    const now = new Date()
    const currentHHMM = `${String(now.getUTCHours()).padStart(2, '0')}:${String(now.getUTCMinutes()).padStart(2, '0')}`
    const todayKey = now.toISOString().split('T')[0]

    // Get all orgs
    const { data: orgs } = await supabase.from('orgs').select('id').eq('is_active', true)
    if (!orgs || orgs.length === 0) {
      return new Response(JSON.stringify({ message: 'No active orgs' }), { status: 200 })
    }

    const results = []

    for (const org of orgs) {
      const orgId = org.id

      // Get cutoff time for this org
      const { data: config } = await supabase
        .from('app_config')
        .select('value')
        .eq('key', 'org.cutoff_time')
        .eq('org_id', orgId)
        .maybeSingle()

      const cutoffTime = config?.value ?? '23:00'

      // Check if already ran today for this org
      const { data: lastRun } = await supabase
        .from('app_config')
        .select('value')
        .eq('key', 'last_cutoff_run')
        .eq('org_id', orgId)
        .maybeSingle()

      if (lastRun?.value === todayKey) {
        results.push({ orgId, status: 'already_ran_today' })
        continue
      }

      // Check if past cutoff time (compare HH:MM strings)
      if (currentHHMM < cutoffTime) {
        results.push({ orgId, status: 'not_yet', cutoffTime, currentHHMM })
        continue
      }

      // Close all open trips for this org
      const nowSeconds = Math.floor(Date.now() / 1000)
      const { data: closed, error } = await supabase
        .from('trips')
        .update({
          ended_at: new Date().toISOString(),
          close_reason: 'cutoff',
        })
        .eq('org_id', orgId)
        .is('ended_at', null)
        .select('id')

      if (error) {
        results.push({ orgId, status: 'error', error: error.message })
        continue
      }

      // Stamp last run date
      await supabase.from('app_config').upsert({
        key: 'last_cutoff_run',
        value: todayKey,
        org_id: orgId,
      })

      results.push({
        orgId,
        status: 'cutoff_applied',
        tripsClosedCount: closed?.length ?? 0,
        cutoffTime,
      })
    }

    return new Response(JSON.stringify({ results }), { status: 200 })

  } catch (e) {
    return new Response(JSON.stringify({ error: e.message }), { status: 500 })
  }
})
