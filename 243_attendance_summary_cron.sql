-- Attendance summary — TWO pg_cron jobs for ALL tenant orgs.
--
-- These call the attendance-summary edge function once per run; the function
-- loops over every org that enabled it (app_config org.attendance_summary=true)
-- and emails that org's org.attendance_summary_emails recipients. Times are UTC:
--   04:30 UTC = 09:30 PKT  (morning cutoff)
--   13:30 UTC = 18:30 PKT  (evening cutoff)
-- PKT is UTC+5 with no daylight saving, so these are stable year-round.
--
-- AUTH: the edge function has JWT verification ON (Supabase default), so each
-- cron call must carry a credential the gateway accepts. We send the shared
-- service key stored in Vault as `edge_service_key` — the SAME pattern the other
-- reminder crons use (see 216_processor_aging.sql). The function treats any
-- gateway-authorized non-user caller as the scheduled sweep; a real user's JWT
-- (the in-app "Send test now") is instead scoped to that one org.
--
-- NOTE: do NOT go back to the old x-cron-secret placeholder approach — the
-- function was never given a matching CRON_SECRET env var, so that path 401/403s
-- at the gateway. The service-key header below is what actually works.
--
-- Requires the pg_cron + pg_net extensions and the `edge_service_key` Vault
-- secret (already present, used by the other digests). Re-running is safe.

DO $do$
declare v_key text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — attendance-summary crons not scheduled';
    return;
  end if;

  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'edge_service_key' limit 1;
  if v_key is null then
    raise exception 'edge_service_key not found in Vault — cannot schedule attendance-summary crons';
  end if;

  -- Re-running is safe: unschedule existing jobs of the same name first.
  if exists (select 1 from cron.job where jobname = 'attendance-summary-morning') then
    perform cron.unschedule('attendance-summary-morning');
  end if;
  if exists (select 1 from cron.job where jobname = 'attendance-summary-evening') then
    perform cron.unschedule('attendance-summary-evening');
  end if;

  -- 09:30 PKT — morning cutoff
  perform cron.schedule(
    'attendance-summary-morning',
    '30 4 * * *',
    format($cron$
      select net.http_post(
        url     := 'https://xgptodkasmytddmdnbtb.supabase.co/functions/v1/attendance-summary?slot=morning',
        headers := jsonb_build_object(
                     'Content-Type', 'application/json',
                     'Authorization', 'Bearer %s'),
        body    := '{}'::jsonb);
    $cron$, v_key));

  -- 18:30 PKT — evening cutoff
  perform cron.schedule(
    'attendance-summary-evening',
    '30 13 * * *',
    format($cron$
      select net.http_post(
        url     := 'https://xgptodkasmytddmdnbtb.supabase.co/functions/v1/attendance-summary?slot=evening',
        headers := jsonb_build_object(
                     'Content-Type', 'application/json',
                     'Authorization', 'Bearer %s'),
        body    := '{}'::jsonb);
    $cron$, v_key));

  raise notice 'Scheduled attendance-summary morning (04:30 UTC) and evening (13:30 UTC) with service-key auth.';
end $do$;

-- Verify:
--   select jobname, schedule from cron.job where jobname like 'attendance-summary%';
--
-- Fire on demand + read the reply (should be 200 with "sent">=1):
--   do $$ declare v_key text; begin
--     select decrypted_secret into v_key from vault.decrypted_secrets where name='edge_service_key' limit 1;
--     perform net.http_post(
--       url := 'https://xgptodkasmytddmdnbtb.supabase.co/functions/v1/attendance-summary?slot=morning',
--       headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
--       body := '{}'::jsonb);
--   end $$;
--   select status_code, left(content,300) as body, created
--     from net._http_response order by created desc limit 3;
