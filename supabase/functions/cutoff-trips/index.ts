import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// Pakistan is UTC+5, no DST. All cut-off reasoning happens in this zone: the
// stored org.cutoff_time (e.g. "23:00") is Karachi local wall-clock, and a
// trip belongs to the Karachi calendar day it started on.
const KARACHI_OFFSET_MS = 5 * 60 * 60 * 1000

/** A Date shifted so its UTC fields read as Karachi local wall-clock. */
function toKarachi(d: Date): Date {
  return new Date(d.getTime() + KARACHI_OFFSET_MS)
}

/** Real UTC instant for a given Karachi Y-M-D at HH:MM. */
function karachiWallToUtc(
  year: number,
  month: number, // 1-12
  day: number,
  hh: number,
  mm: number,
): Date {
  const asIfUtc = Date.UTC(year, month - 1, day, hh, mm, 0, 0)
  return new Date(asIfUtc - KARACHI_OFFSET_MS)
}

/** YYYY-MM-DD for a Karachi-shifted date. */
function karachiDateKey(karachiShifted: Date): string {
  const y = karachiShifted.getUTCFullYear()
  const m = String(karachiShifted.getUTCMonth() + 1).padStart(2, '0')
  const d = String(karachiShifted.getUTCDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}

serve(async (_req) => {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)

    const nowUtc = new Date()
    const nowKarachi = toKarachi(nowUtc)
    const nowMinutes = nowKarachi.getUTCHours() * 60 + nowKarachi.getUTCMinutes()
    const todayKey = karachiDateKey(nowKarachi) // Karachi calendar day

    const { data: orgs } = await supabase
      .from('orgs')
      .select('id')
      .eq('is_active', true)
    if (!orgs || orgs.length === 0) {
      return new Response(JSON.stringify({ message: 'No active orgs' }), {
        status: 200,
      })
    }

    const results: unknown[] = []

    for (const org of orgs) {
      const orgId = org.id

      // Cut-off time for this org (Karachi local HH:MM). Default 23:00.
      const { data: config } = await supabase
        .from('app_config')
        .select('value')
        .eq('key', 'org.cutoff_time')
        .eq('org_id', orgId)
        .maybeSingle()

      const cutoffTime = (config?.value ?? '23:00') as string
      const [cutH, cutM] = cutoffTime.split(':').map((s) => parseInt(s, 10))
      if (Number.isNaN(cutH) || Number.isNaN(cutM)) {
        results.push({ orgId, status: 'bad_cutoff_config', cutoffTime })
        continue
      }
      const cutoffMinutes = cutH * 60 + cutM

      // Fire ONCE per Karachi day. This is what makes the cut-off a single
      // moment — a sweep at (or just after) the cut-off time — rather than a
      // condition that stays true all day and keeps killing freshly-started
      // trips. Trips started AFTER today's sweep are safe until tomorrow.
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

      // Not yet at today's Karachi cut-off — wait for it.
      if (nowMinutes < cutoffMinutes) {
        results.push({ orgId, status: 'not_yet', cutoffTime })
        continue
      }

      // The moment has arrived: close every open trip for this org, each
      // backdated to ITS OWN Karachi start-day cut-off.
      const { data: openTrips, error: selErr } = await supabase
        .from('trips')
        .select('id, started_at')
        .eq('org_id', orgId)
        .is('ended_at', null)

      if (selErr) {
        results.push({ orgId, status: 'error', error: selErr.message })
        continue
      }

      let closed = 0
      for (const t of openTrips ?? []) {
        const startedUtc = new Date(t.started_at as string)
        const startedKarachi = toKarachi(startedUtc)

        // Cut-off instant of THIS trip's own Karachi start day — never "now".
        let endUtc = karachiWallToUtc(
          startedKarachi.getUTCFullYear(),
          startedKarachi.getUTCMonth() + 1,
          startedKarachi.getUTCDate(),
          cutH,
          cutM,
        )
        // Clamp: never before the trip started (a trip begun after its own
        // cut-off, e.g. 23:30 with a 23:00 cut-off) and never in the future.
        if (endUtc.getTime() < startedUtc.getTime()) endUtc = startedUtc
        if (endUtc.getTime() > nowUtc.getTime()) endUtc = nowUtc

        const { error: updErr } = await supabase
          .from('trips')
          .update({ ended_at: endUtc.toISOString(), close_reason: 'cutoff' })
          .eq('id', t.id)

        if (updErr) {
          results.push({
            orgId,
            tripId: t.id,
            status: 'update_error',
            error: updErr.message,
          })
          continue
        }
        closed++
      }

      // Stamp the day as done so we don't sweep again until tomorrow.
      await supabase.from('app_config').upsert({
        key: 'last_cutoff_run',
        value: todayKey,
        org_id: orgId,
      })

      results.push({
        orgId,
        status: 'cutoff_applied',
        tripsClosedCount: closed,
        cutoffTime,
      })
    }

    return new Response(JSON.stringify({ results }), { status: 200 })
  } catch (e) {
    return new Response(JSON.stringify({ error: (e as Error).message }), {
      status: 500,
    })
  }
})
