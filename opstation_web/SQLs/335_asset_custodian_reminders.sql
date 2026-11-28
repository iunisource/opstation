-- 335 — Assets: custodians from employees + maintenance reminders sent to the
-- custodian directly (SMS to their phone + email if they have one).
--
--   * asset_custodians gets email + employee_id (custodians can be picked from HR).
--   * asset_custodian_reminders(p_dry) — daily, for orgs with
--     Admin Settings ▸ "Remind custodians directly" ON:
--       for every asset whose next maintenance is within the lead time
--       (org.asset_maintenance_reminder_days, default 7) or overdue, and whose
--       custodian has a phone and/or email:
--         - SMS via the org's SMS gateway (Settings ▸ SMS Notifications, must be enabled)
--         - email via the app's mailer
--       Cadence per asset & due date: once when it enters the window, once on
--       the due day, then weekly while overdue. Every send is logged.
--     p_dry = true previews who would be messaged without sending anything.
--   * pg_cron: daily 04:05 UTC (09:05 PKT).
-- Safe to run again.

alter table public.asset_custodians add column if not exists email text;
alter table public.asset_custodians add column if not exists employee_id text;

create table if not exists public.asset_reminder_log (
  id           bigint generated always as identity primary key,
  org_id       text not null,
  asset_id     text not null,
  custodian_id text,
  due_date     date not null,
  channel      text not null,          -- sms | email
  target       text,
  status       text not null,          -- queued | skipped | error
  detail       text,
  sent_at      timestamptz not null default now()
);
create index if not exists asset_reminder_log_idx on public.asset_reminder_log(asset_id, due_date, sent_at desc);
alter table public.asset_reminder_log enable row level security;
drop policy if exists arl_read on public.asset_reminder_log;
create policy arl_read on public.asset_reminder_log for select using (public._is_org_member(org_id));

create or replace function public._urlencode(p text)
returns text language sql immutable as $$
  select coalesce(string_agg(
           case when b between 48 and 57 or b between 65 and 90 or b between 97 and 122 or b in (45, 46, 95, 126)
                then chr(b) else '%' || upper(lpad(to_hex(b), 2, '0')) end, '' order by i), '')
  from (select get_byte(convert_to(coalesce(p, ''), 'UTF8'), i) as b, i
          from generate_series(0, length(convert_to(coalesce(p, ''), 'UTF8')) - 1) i) x;
$$;

-- Send one SMS through the org's configured gateway. Returns 'queued' or an error text.
create or replace function public._sms_send(p_org text, p_phone text, p_message text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare
  c jsonb; v_url text; v_method text; v_body text; v_hdr text; v_key text; v_sender text; v_phone text;
  jstr text;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into c
    from app_config where org_id = p_org and key like 'org.sms_%';
  if coalesce(c->>'org.sms_enabled', '') <> 'true' then return 'sms not enabled'; end if;
  v_url := nullif(trim(coalesce(c->>'org.sms_api_url', '')), '');
  if v_url is null then return 'sms url not set'; end if;
  v_method := upper(coalesce(nullif(c->>'org.sms_api_method', ''), 'GET'));
  v_key := coalesce(c->>'org.sms_api_key', '');
  v_sender := coalesce(c->>'org.sms_sender_id', '');
  v_phone := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
  if v_phone = '' then return 'no phone'; end if;

  v_url := replace(replace(replace(replace(v_url,
             '{phone}', _urlencode(v_phone)), '{message}', _urlencode(p_message)),
             '{api_key}', _urlencode(v_key)), '{sender_id}', _urlencode(v_sender));
  v_hdr := replace(replace(coalesce(nullif(trim(c->>'org.sms_api_headers'), ''), '{}'),
             '{api_key}', v_key), '{sender_id}', v_sender);

  if v_method = 'GET' then
    perform net.http_get(url := v_url, headers := v_hdr::jsonb);
  else
    -- body template is JSON; placeholders are filled with JSON-escaped text
    jstr := coalesce(nullif(trim(c->>'org.sms_api_body'), ''), '{"to":"{phone}","message":"{message}"}');
    v_body := replace(replace(replace(replace(jstr,
                '{phone}', substr(to_json(v_phone)::text, 2, length(to_json(v_phone)::text) - 2)),
                '{message}', substr(to_json(p_message)::text, 2, length(to_json(p_message)::text) - 2)),
                '{api_key}', substr(to_json(v_key)::text, 2, length(to_json(v_key)::text) - 2)),
                '{sender_id}', substr(to_json(v_sender)::text, 2, length(to_json(v_sender)::text) - 2));
    perform net.http_post(url := v_url, body := v_body::jsonb,
                          headers := ('{"Content-Type":"application/json"}'::jsonb || v_hdr::jsonb));
  end if;
  return 'queued';
exception when others then
  return 'error: ' || sqlerrm;
end $$;
revoke all on function public._sms_send(text, text, text) from public, anon, authenticated;

create or replace function public.asset_custodian_reminders(p_dry boolean default false)
returns json language plpgsql security definer set search_path to 'public' as $$
declare
  o record; r record; v_days int; v_org_name text; v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_last date; v_send boolean; v_msg text; v_title text; v_st text; v_url text;
  n_sms int := 0; n_mail int := 0; n_skip int := 0; preview jsonb := '[]'::jsonb;
begin
  for o in
    select distinct org_id from app_config
     where key = 'org.asset_custodian_reminder' and value = 'true'
  loop
    select coalesce(nullif(value, '')::int, 7) into v_days
      from app_config where org_id = o.org_id and key = 'org.asset_maintenance_reminder_days' limit 1;
    v_days := coalesce(v_days, 7);
    select name into v_org_name from orgs where id = o.org_id;

    for r in
      select a.id, a.asset_code, a.name, a.next_maintenance_due::date as due, a.public_token,
             c.id as cid, c.name as cname, nullif(trim(c.phone), '') as phone, nullif(trim(c.email), '') as email
        from assets a
        join asset_custodians c on c.id = a.assigned_to and coalesce(c.is_active, true)
       where a.org_id = o.org_id and coalesce(a.is_active, true)
         and a.next_maintenance_due is not null
         and a.next_maintenance_due::date <= v_today + v_days
         and (nullif(trim(c.phone), '') is not null or nullif(trim(c.email), '') is not null)
    loop
      select max(sent_at::date) into v_last from asset_reminder_log
       where asset_id = r.id and due_date = r.due and status = 'queued';
      v_send := v_last is null                                   -- entered the window
             or (r.due = v_today and v_last < v_today)           -- due today
             or (r.due < v_today and v_last <= v_today - 7);     -- weekly while overdue
      if not v_send then n_skip := n_skip + 1; continue; end if;

      v_msg := coalesce(v_org_name, 'Opstation') || ': maintenance of ' || r.asset_code || ' ' || r.name ||
               case when r.due < v_today then ' is OVERDUE (was due ' || to_char(r.due, 'DD Mon YYYY') || ')'
                    when r.due = v_today then ' is due TODAY'
                    else ' is due on ' || to_char(r.due, 'DD Mon YYYY') end ||
               '. Please arrange servicing.';

      if p_dry then
        preview := preview || jsonb_build_object('asset', r.asset_code, 'custodian', r.cname,
                     'sms', r.phone, 'email', r.email, 'due', r.due, 'message', v_msg);
        continue;
      end if;

      if r.phone is not null then
        v_st := public._sms_send(o.org_id, r.phone, v_msg);
        insert into asset_reminder_log(org_id, asset_id, custodian_id, due_date, channel, target, status, detail)
        values (o.org_id, r.id, r.cid, r.due, 'sms', r.phone,
                case when v_st = 'queued' then 'queued' when v_st like 'error%' then 'error' else 'skipped' end, v_st);
        if v_st = 'queued' then n_sms := n_sms + 1; end if;
      end if;

      if r.email is not null and r.email like '%@%' then
        begin
          v_title := 'Maintenance ' || case when r.due < v_today then 'overdue' else 'due' end || ' — ' || r.asset_code || ' ' || r.name;
          v_url := 'https://opstation-f06c7.web.app/asset.html?t=' || coalesce(r.public_token, '');
          perform public._email_send(r.email, v_title || coalesce(' · ' || v_org_name, ''),
                    public._email_simple_html(v_org_name, v_title, 'Dear ' || r.cname || ', ' || v_msg, v_url),
                    v_msg || E'\n\nAsset details: ' || v_url);
          insert into asset_reminder_log(org_id, asset_id, custodian_id, due_date, channel, target, status, detail)
          values (o.org_id, r.id, r.cid, r.due, 'email', r.email, 'queued', null);
          n_mail := n_mail + 1;
        exception when others then
          insert into asset_reminder_log(org_id, asset_id, custodian_id, due_date, channel, target, status, detail)
          values (o.org_id, r.id, r.cid, r.due, 'email', r.email, 'error', sqlerrm);
        end;
      end if;
    end loop;
  end loop;

  if p_dry then return json_build_object('dry_run', true, 'would_send', preview, 'not_due_again_yet', n_skip); end if;
  return json_build_object('sms', n_sms, 'emails', n_mail, 'not_due_again_yet', n_skip);
end $$;
revoke all on function public.asset_custodian_reminders(boolean) from public, anon, authenticated;

do $do$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — custodian reminders not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'asset-custodian-reminders') then
    perform cron.unschedule('asset-custodian-reminders');
  end if;
  perform cron.schedule('asset-custodian-reminders', '5 4 * * *', 'select public.asset_custodian_reminders();');
end $do$;

select 'installed' as status,
       (select count(*) from cron.job where jobname = 'asset-custodian-reminders') as scheduled;
