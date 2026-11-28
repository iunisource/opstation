-- 298 — Notifications centre: "Send test" button.
-- Sends a test for one event to everyone added to it, on their ticked
-- channels, ignoring branch limits. "Document creator" receives it as the
-- master admin who pressed the button. Master admin only. Requires 296.

create or replace function public.notify_test_event(p_org text, p_event text, p_title text default null)
returns json
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_me text; v_name text; v_org_name text; v_app text;
  v_push text[]; v_emails text[]; v_notif text; e text;
  v_title text := 'Test: ' || coalesce(nullif(p_title, ''), p_event);
  v_body text;
begin
  if not public._is_org_master(p_org) then
    return json_build_object('ok', false, 'message', 'Only the master admin can send tests.');
  end if;
  if exists (select 1 from public.notification_event_state
              where org_id = p_org and event_key = p_event and not enabled) then
    return json_build_object('ok', false, 'message', 'This notification is paused — switch it on to test.');
  end if;

  select id, name into v_me, v_name from public.users
   where org_id = p_org
     and (account_id = public.current_account_id()
          or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')))
   limit 1;
  v_body := 'This is a test sent by ' || coalesce(v_name, 'the master admin')
         || '. You will receive real alerts like this when it happens.';

  select array_agg(distinct x.uid) into v_push
    from (select case when r.user_id = '__creator__' then v_me else r.user_id end as uid
            from public.notification_rules r
           where r.org_id = p_org and r.event_key = p_event and r.push and r.user_id is not null) x
    join public.users u on u.id = x.uid and u.org_id = p_org and coalesce(u.is_active, true);

  if v_push is not null then
    begin
      perform public.push_send(p_org, v_push, v_title, v_body, '/erp/admin-settings');
    exception when others then null;
    end;
    begin
      insert into public.notifications
        (org_id, title, body, audience, audience_roles, link_url, created_by, origin)
      values (p_org, v_title, v_body, 'roles', '{}'::text[], '/erp/admin-settings', coalesce(v_me, v_push[1]), 'system')
      returning id::text into v_notif;
      insert into public.notification_recipients (notification_id, recipient_user_id)
      select v_notif, unnest(v_push);
    exception when others then null;
    end;
  end if;

  select array_agg(distinct lower(trim(x.addr))) into v_emails
    from (select case
                   when r.email is not null then r.email
                   when r.user_id = '__creator__' then (select u.email from public.users u where u.id = v_me)
                   else (select u.email from public.users u
                          where u.id = r.user_id and u.org_id = p_org and coalesce(u.is_active, true))
                 end as addr
            from public.notification_rules r
           where r.org_id = p_org and r.event_key = p_event and r.email_on) x
   where x.addr like '%@%';

  if v_emails is not null then
    select name into v_org_name from public.orgs where id = p_org;
    select app_url into v_app from public.email_action_config where id = 1;
    v_app := coalesce(v_app, 'https://opstation-f06c7.web.app');
    foreach e in array v_emails loop
      begin
        perform public._email_send(e, v_title || coalesce(' · ' || nullif(v_org_name, ''), ''),
          public._email_simple_html(v_org_name, v_title, v_body, v_app || '/#/erp/admin-settings'),
          v_title || E'\n' || v_body);
      exception when others then null;
      end;
    end loop;
  end if;

  return json_build_object('ok', true,
    'push', coalesce(array_length(v_push, 1), 0),
    'email', coalesce(array_length(v_emails, 1), 0));
end $$;

revoke all on function public.notify_test_event(text, text, text) from public, anon;
grant execute on function public.notify_test_event(text, text, text) to authenticated;
