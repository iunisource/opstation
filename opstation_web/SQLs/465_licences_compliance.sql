-- 465 — Management → Licences & Compliance.
--
--  • compliance_items: what the company must hold or renew (fire safety
--    certificate, trade licence, EOBI, insurance …) with authority, reference,
--    issue / expiry, how it repeats, remind-before days, responsible person,
--    an optional linked Facility schedule, and documents.
--  • compliance_renewals: every renewal — the old expiry and documents are kept.
--  • compliance_renew(): records a renewal in one step.
--  • compliance_due_count(): the menu counter (due + expired).
--  • compliance_reminders(): nightly — push + bell to the item's responsible
--    person and the users in org.compliance_alert_users: once when it comes
--    due (remind_days before expiry), once on expiry, then weekly while
--    expired. Switched on by Admin Settings → org.compliance_reminders.
--  • Storage bucket compliance-files.
-- Safe to run again.

create table if not exists public.compliance_items (
  id                   text primary key default ('cmp_' || replace(gen_random_uuid()::text, '-', '')),
  org_id               text not null,
  title                text not null,
  category             text not null default 'other',
  branch_id            text,                       -- null = all branches
  authority            text,
  reference_no         text,
  issued_on            date,
  expires_on           date,
  repeat               text not null default 'yearly', -- none | monthly | quarterly | yearly | years
  repeat_years         int,
  remind_days          int not null default 30,
  responsible_user_id  text,
  cost                 numeric,
  facility_schedule_id text,
  in_renewal_since     date,
  documents            jsonb not null default '[]'::jsonb,
  notes                text,
  is_active            boolean not null default true,
  created_by_name      text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index if not exists compliance_items_org on public.compliance_items (org_id);

create table if not exists public.compliance_renewals (
  id           text primary key default ('cmr_' || replace(gen_random_uuid()::text, '-', '')),
  org_id       text not null,
  item_id      text not null,
  old_issued   date,
  old_expiry   date,
  new_issued   date,
  new_expiry   date,
  cost         numeric,
  note         text,
  documents    jsonb not null default '[]'::jsonb,   -- the documents of the period that ended
  by_name      text,
  created_at   timestamptz not null default now()
);
create index if not exists compliance_renewals_item on public.compliance_renewals (item_id);

create table if not exists public.compliance_alert_log (
  id       bigint generated always as identity primary key,
  org_id   text not null,
  item_id  text not null,
  cycle    text not null,
  stage    text not null,                     -- due | expired
  sent_at  timestamptz not null default now()
);
create index if not exists compliance_alert_log_item on public.compliance_alert_log (item_id, cycle);

do $$
declare t text;
begin
  foreach t in array array['compliance_items','compliance_renewals'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_org', t);
    execute format('create policy %I on public.%I for all using (public._is_org_member(org_id) or public._is_super_admin())
                    with check (public._is_org_member(org_id) or public._is_super_admin())', t || '_org', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
alter table public.compliance_alert_log enable row level security;
revoke all on public.compliance_alert_log from anon, authenticated;

insert into storage.buckets (id, name, public) values ('compliance-files', 'compliance-files', true)
on conflict (id) do nothing;
drop policy if exists compliance_files_read on storage.objects;
create policy compliance_files_read on storage.objects for select using (bucket_id = 'compliance-files');
drop policy if exists compliance_files_write on storage.objects;
create policy compliance_files_write on storage.objects for insert to authenticated
  with check (bucket_id = 'compliance-files' and public._is_org_member((storage.foldername(name))[1]));
drop policy if exists compliance_files_delete on storage.objects;
create policy compliance_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'compliance-files' and public._is_org_member((storage.foldername(name))[1]));

create or replace function public.compliance_my_name(p_org text)
returns text language sql stable security definer set search_path to 'public' as $$
  select a.name from public._acting_user(p_org) a limit 1
$$;
grant execute on function public.compliance_my_name(text) to authenticated;

-- Renew: keep the old period in history, move the item to the new dates.
create or replace function public.compliance_renew(p_item text, p_new_issued date, p_new_expiry date,
                                                  p_cost numeric default null, p_note text default null,
                                                  p_documents jsonb default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c compliance_items%rowtype; v_name text;
begin
  select * into c from compliance_items where id = p_item;
  if c.id is null then raise exception 'Item not found.'; end if;
  if not (public._is_org_member(c.org_id) or public._is_super_admin()) then raise exception 'No access.'; end if;
  if p_new_expiry is null then raise exception 'Enter the new expiry date.'; end if;
  select a.name into v_name from public._acting_user(c.org_id) a;
  insert into compliance_renewals (org_id, item_id, old_issued, old_expiry, new_issued, new_expiry, cost, note, documents, by_name)
  values (c.org_id, c.id, c.issued_on, c.expires_on, coalesce(p_new_issued, (now() at time zone 'Asia/Karachi')::date),
          p_new_expiry, p_cost, nullif(btrim(coalesce(p_note, '')), ''), c.documents, v_name);
  update compliance_items
     set issued_on = coalesce(p_new_issued, (now() at time zone 'Asia/Karachi')::date),
         expires_on = p_new_expiry,
         cost = coalesce(p_cost, cost),
         documents = coalesce(p_documents, '[]'::jsonb),
         in_renewal_since = null,
         updated_at = now()
   where id = c.id;
end $$;
grant execute on function public.compliance_renew(text, date, date, numeric, text, jsonb) to authenticated;

-- due | expired | ok, for one item.
create or replace function public._compliance_state(p_expires date, p_remind int)
returns text language sql stable as $$
  select case
           when p_expires is null then 'ok'
           when p_expires < (now() at time zone 'Asia/Karachi')::date then 'expired'
           when p_expires <= (now() at time zone 'Asia/Karachi')::date + coalesce(p_remind, 30) then 'due'
           else 'ok' end
$$;

create or replace function public.compliance_due_count(p_org text)
returns int language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then return 0; end if;
  return (select count(*) from compliance_items
           where org_id = p_org and is_active and public._compliance_state(expires_on, remind_days) <> 'ok');
end $$;
grant execute on function public.compliance_due_count(text) to authenticated;

create or replace function public.compliance_reminders()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  o record; r record; v_users text[]; v_ids text[]; v_stage text; v_cycle text; v_last timestamptz;
  v_title text; v_body text; v_notif text; v_branch text; v_resp text; n int := 0;
begin
  for o in select distinct org_id from app_config where key = 'org.compliance_reminders' and value = 'true' loop
    select string_to_array(replace(coalesce(value, ''), ' ', ''), ',') into v_users
      from app_config where org_id = o.org_id and key = 'org.compliance_alert_users' and branch_id is null limit 1;
    for r in select * from compliance_items where org_id = o.org_id and is_active and expires_on is not null loop
      v_stage := public._compliance_state(r.expires_on, r.remind_days);
      if v_stage = 'ok' then continue; end if;
      if v_stage = 'due' and r.in_renewal_since is not null then continue; end if; -- already being renewed
      v_cycle := r.expires_on::text;
      select max(sent_at) into v_last from compliance_alert_log where item_id = r.id and cycle = v_cycle and stage = v_stage;
      if v_last is not null and (v_stage = 'due' or v_last > now() - interval '7 days') then continue; end if;

      select name into v_branch from branches where id = r.branch_id;
      select name into v_resp from users where id = r.responsible_user_id;
      if v_stage = 'expired' then
        v_title := 'EXPIRED — ' || r.title;
        v_body := coalesce(v_branch, 'All branches') || ' · expired ' || to_char(r.expires_on, 'DD Mon YYYY') ||
                  '. Renew it and upload the new certificate.';
      else
        v_title := r.title || ' due' || coalesce(' — ' || v_branch, '');
        v_body := 'Due ' || to_char(r.expires_on, 'DD Mon YYYY') || ' (in ' ||
                  (r.expires_on - (now() at time zone 'Asia/Karachi')::date) || ' days)' ||
                  coalesce('. Responsible: ' || v_resp, '') || '.';
      end if;

      select array_agg(distinct u.id) into v_ids from users u
       where u.org_id = o.org_id and coalesce(u.is_active, true)
         and (u.id = r.responsible_user_id or u.id = any (coalesce(v_users, '{}')));
      if v_ids is null then continue; end if;
      begin
        perform public.push_send(o.org_id, v_ids, v_title, v_body, '/licences?i=' || r.id);
      exception when others then null;
      end;
      begin
        insert into notifications (org_id, title, body, audience, audience_roles, link_url, created_by, origin)
        values (o.org_id, v_title, v_body, 'roles', '{}'::text[], '/licences?i=' || r.id, v_ids[1], 'system')
        returning id::text into v_notif;
        insert into notification_recipients (notification_id, recipient_user_id) select v_notif, unnest(v_ids);
      exception when others then null;
      end;
      insert into compliance_alert_log (org_id, item_id, cycle, stage) values (o.org_id, r.id, v_cycle, v_stage);
      n := n + 1;
    end loop;
  end loop;
  return jsonb_build_object('alerts', n);
end $$;
revoke all on function public.compliance_reminders() from public, anon, authenticated;

do $do$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — compliance reminders not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'compliance-reminders') then
    perform cron.unschedule('compliance-reminders');
  end if;
  perform cron.schedule('compliance-reminders', '25 4 * * *', 'select public.compliance_reminders();');
end $do$;
