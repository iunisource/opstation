-- 294 — "Go to screen" in the Payment Advice approval email now opens that
-- exact advice (…/payment-advice?focus=<id>), like the PO email already does.
create or replace function public._email_doc_notify(p_kind text, p_id text)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare
  d json; v_org text; v_on text; v_csv text; v_app text; v_open text;
  v_email text; v_uid text; v_rights json; v_token text; v_subj text; v_text text;
begin
  -- once per submission
  insert into public.email_doc_sent(kind, doc_id) values (p_kind, p_id)
  on conflict do nothing;
  if not found then return; end if;

  d := public._email_doc(p_kind, p_id);
  if d is null or d->>'state' <> 'pending' then return; end if;
  v_org := d->>'org_id';

  select value into v_on  from public.app_config where org_id = v_org
     and key = case when p_kind = 'po' then 'org.po_notify_new' else 'org.pa_notify_new' end limit 1;
  if coalesce(v_on, '') <> 'true' then return; end if;
  select value into v_csv from public.app_config where org_id = v_org
     and key = case when p_kind = 'po' then 'org.po_notify_emails' else 'org.pa_notify_emails' end limit 1;

  select app_url into v_app from public.email_action_config where id = 1;
  v_app := coalesce(v_app, 'https://opstation-f06c7.web.app');
  v_open := v_app || case when p_kind = 'po' then '/#/erp/purchase?focus=' || p_id
                          else '/#/financials/payment-advice?focus=' || p_id end;

  v_subj := 'Approval needed: ' || coalesce(d->>'number', d->>'title')
         || case when p_kind = 'po' and coalesce(d->>'supplier_name', '') <> '' then ' · ' || (d->>'supplier_name') else '' end
         || case when p_kind = 'pa' or coalesce((d->>'show_rates')::boolean, false) then ' · ' || _rs((d->>'total')::numeric) else '' end;
  v_text := (d->>'title') || ' ' || coalesce(d->>'number', '') || ' is awaiting approval'
         || case when coalesce(d->>'created_by_name', '') <> '' then ' (submitted by ' || (d->>'created_by_name') || ')' else '' end
         || '. Open: ' || v_open;

  for v_email in
    select distinct lower(trim(x)) from unnest(regexp_split_to_array(coalesce(v_csv, ''), '[,;\s]+')) x
     where trim(x) like '%@%'
  loop
    begin
      v_token := null; v_uid := null;
      select id into v_uid from public.users
       where org_id = v_org and lower(email) = v_email and coalesce(is_active, true) = true
       limit 1;
      if v_uid is not null then
        v_rights := public._email_actor_rights(p_kind, v_org, v_uid, d->>'branch_id');
        if coalesce((v_rights->>'can_approve')::boolean, false) or coalesce((v_rights->>'can_reject')::boolean, false) then
          insert into public.email_action_tokens(kind, doc_id, org_id, user_id, email)
          values (p_kind, p_id, v_org, v_uid, v_email)
          returning token into v_token;
        end if;
      end if;
      perform public._email_send(v_email, v_subj,
                                 public._email_doc_html(d, v_token, v_open, v_app), v_text);
    exception when others then
      null;  -- one bad address must not stop the others
    end;
  end loop;
end $$;

revoke all on function public._email_doc_notify(text, text) from public, anon, authenticated;
