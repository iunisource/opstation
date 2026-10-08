-- 332 — Performance watchdog (super admin only).
--
-- Every morning (08:50 PKT) the database checks itself:
--   1. Re-runs rls_optimize_all() (SQL 331) — auto-fixes any permission rule
--      that slipped in un-optimised.
--   2. Looks at the app's requests since the last check (pg_stat_statements)
--      and flags any that averaged ≥ 1 s (3+ calls) or took ≥ 6 s even once
--      (the cut-off is 8 s).
--   3. If anything is flagged, emails every active super admin (+ bell / push
--      where the super admin has an org) with the list. Nothing found = no email.
--   4. Clears the counters so tomorrow's check covers just that day.
-- Master admins / org users never see any of this.
-- Manual test (always emails, even when all clear):  select public.perf_watchdog(true);
-- Safe to run again.

create table if not exists public.perf_watch_log (
  id          bigint generated always as identity primary key,
  checked_at  timestamptz not null default now(),
  slow_count  int,
  rls_fixed   int,
  findings    jsonb,
  emailed_to  text[]
);
alter table public.perf_watch_log enable row level security;   -- no policies: not readable from the app

create or replace function public.perf_watchdog(p_force boolean default false)
returns json
language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_catalog'
as $$
declare
  v_rows jsonb; v_n int := 0; v_fix int := 0; v_to text[]; v_since timestamptz;
  v_html text; v_text text; v_trs text := ''; v_lines text := ''; v_app text; v_subject text;
  r record; e text; v_notif text;
begin
  -- 1. auto-fix permission rules
  begin
    select changed into v_fix from public.rls_optimize_all();
  exception when others then v_fix := -1;
  end;

  select max(checked_at) into v_since from public.perf_watch_log where findings is not null or slow_count is not null;

  -- 2. slow app requests since the last reset
  select coalesce(jsonb_agg(to_jsonb(x) order by x.max_ms desc), '[]'::jsonb), count(*)
    into v_rows, v_n
  from (
    select s.calls::bigint                    as calls,
           round(s.mean_exec_time)::int       as avg_ms,
           round(s.max_exec_time)::int        as max_ms,
           round(s.total_exec_time / 1000)::int as total_s,
           left(regexp_replace(s.query, '\s+', ' ', 'g'), 300) as query
      from pg_stat_statements s
      join pg_roles ro on ro.oid = s.userid
     where ro.rolname in ('authenticated', 'anon', 'service_role')
       and ((s.mean_exec_time >= 1000 and s.calls >= 3) or s.max_exec_time >= 6000)
     order by s.max_exec_time desc
     limit 15
  ) x;

  select array_agg(distinct lower(trim(u.email))) into v_to
    from public.users u
   where u.role = 'superAdmin' and coalesce(u.is_active, true) and u.email like '%@%';

  -- 3. alert
  if (v_n > 0 or p_force) and v_to is not null then
    select app_url into v_app from public.email_action_config where id = 1;
    v_app := coalesce(v_app, 'https://opstation-f06c7.web.app');

    for r in select * from jsonb_to_recordset(v_rows)
               as t(calls bigint, avg_ms int, max_ms int, total_s int, query text) loop
      v_trs := v_trs
        || '<tr><td style="padding:6px 8px;border-top:1px solid #eee;text-align:right">' || r.avg_ms || '</td>'
        || '<td style="padding:6px 8px;border-top:1px solid #eee;text-align:right;color:'
        || case when r.max_ms >= 6000 then '#B91C1C' else '#111' end || '"><b>' || r.max_ms || '</b></td>'
        || '<td style="padding:6px 8px;border-top:1px solid #eee;text-align:right">' || r.calls || '</td>'
        || '<td style="padding:6px 8px;border-top:1px solid #eee;font-family:monospace;font-size:11px;color:#374151">'
        || replace(replace(replace(r.query, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</td></tr>';
      v_lines := v_lines || '• avg ' || r.avg_ms || ' ms, max ' || r.max_ms || ' ms, ' || r.calls || ' calls — '
                 || left(r.query, 160) || E'\n';
    end loop;

    v_subject := case when v_n > 0 then 'Opstation performance: ' || v_n || ' slow request' || case when v_n = 1 then '' else 's' end
                      else 'Opstation performance: all clear (test)' end;

    v_html := '<div style="font-family:Arial,sans-serif;color:#111;max-width:900px">'
      || '<h2 style="margin:0 0 4px">' || v_subject || '</h2>'
      || '<p style="color:#6B7280;margin:0 0 14px">Window: '
      || coalesce(to_char(v_since at time zone 'Asia/Karachi', 'DD Mon HH24:MI'), 'last reset') || ' → '
      || to_char(now() at time zone 'Asia/Karachi', 'DD Mon HH24:MI') || ' PKT · flagged = avg ≥ 1 s or any run ≥ 6 s (cut-off 8 s)'
      || case when v_fix > 0 then ' · auto-fixed ' || v_fix || ' permission rule(s)' else '' end || '</p>'
      || case when v_n > 0 then
           '<table style="border-collapse:collapse;width:100%;font-size:13px">'
           || '<tr style="background:#F3F4F6"><th style="padding:6px 8px;text-align:right">Avg ms</th>'
           || '<th style="padding:6px 8px;text-align:right">Max ms</th><th style="padding:6px 8px;text-align:right">Calls</th>'
           || '<th style="padding:6px 8px;text-align:left">Request</th></tr>' || v_trs || '</table>'
           || '<p style="margin-top:14px">Paste this email to Claude to get it fixed.</p>'
         else '<p>No slow requests. The watchdog is working.</p>' end
      || '<p style="color:#9CA3AF;font-size:11px;margin-top:18px">Super admin only · Opstation performance watchdog</p></div>';
    v_text := v_subject || E'\n\n' || coalesce(nullif(v_lines, ''), 'No slow requests.') ;

    foreach e in array v_to loop
      begin
        perform public._email_send(e, v_subject, v_html, v_text);
      exception when others then null;
      end;
    end loop;

    -- bell + push for super admins that sit in an org
    for r in select u.org_id, array_agg(u.id) as ids from public.users u
              where u.role = 'superAdmin' and coalesce(u.is_active, true) and u.org_id is not null
              group by u.org_id loop
      begin
        perform public.push_send(r.org_id, r.ids, v_subject, 'Details sent by email.', '/');
      exception when others then null;
      end;
      begin
        insert into public.notifications (org_id, title, body, audience, audience_roles, link_url, created_by, origin)
        values (r.org_id, v_subject, 'Details sent by email.', 'roles', '{}'::text[], null, r.ids[1], 'system')
        returning id::text into v_notif;
        insert into public.notification_recipients (notification_id, recipient_user_id)
        select v_notif, unnest(r.ids);
      exception when others then null;
      end;
    end loop;
  end if;

  insert into public.perf_watch_log (slow_count, rls_fixed, findings, emailed_to)
  values (v_n, v_fix, v_rows, case when v_n > 0 or p_force then v_to end);

  -- 4. fresh counters for tomorrow (scheduled runs only)
  if not p_force then
    begin
      perform pg_stat_statements_reset();
    exception when others then null;
    end;
  end if;

  return json_build_object('slow', v_n, 'rls_fixed', v_fix, 'emailed', case when v_n > 0 or p_force then v_to end);
end $$;
revoke all on function public.perf_watchdog(boolean) from public, anon, authenticated;

-- Daily at 03:50 UTC = 08:50 PKT
do $do$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — watchdog not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'perf-watchdog') then
    perform cron.unschedule('perf-watchdog');
  end if;
  perform cron.schedule('perf-watchdog', '50 3 * * *', 'select public.perf_watchdog();');
end $do$;

-- Test now: emails every super admin an "all clear (test)" or the current slow list.
select public.perf_watchdog(true);
