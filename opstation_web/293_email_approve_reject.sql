-- 293 — Rich PO / Payment Advice approval emails with Approve / Reject.
--
-- What changes
--   * The "new PO" / "new Payment Advice" emails now carry the whole document
--     (header, lines, total, who submitted it) in a branded layout.
--   * A recipient who is ALSO an approver in Opstation gets Approve and Reject
--     buttons. They open a confirm page (/#/act/<token>) — nothing happens
--     until "Confirm" is pressed, so mail scanners that pre-open links cannot
--     approve anything. Reject asks for a reason.
--   * Each link is personal (one recipient), single-use and expires in 7 days.
--     The action is recorded under that user (name, time, signature + stamp
--     for PA) with an audit-trail entry "… (via email)".
--   * Recipients who are not approvers get the same email with only the
--     "Open in Opstation" button.
--   * Push notifications are untouched: the existing notify triggers keep
--     running; only their plain email call is switched off (their original
--     source is saved in _fn_backup — revert snippet at the bottom).
--
-- Run the WHOLE file once. It is safe to run again.

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. Private settings + backups (no API access)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.email_action_config (
  id          int primary key default 1 check (id = 1),
  send_url    text not null,
  secret      text not null,
  extra_headers jsonb not null default '{}'::jsonb,
  app_url     text not null,
  updated_at  timestamptz not null default now()
);
alter table public.email_action_config enable row level security;
revoke all on public.email_action_config from anon, authenticated;

create table if not exists public._fn_backup (
  name     text primary key,
  src      text not null,
  saved_at timestamptz not null default now()
);
alter table public._fn_backup enable row level security;
revoke all on public._fn_backup from anon, authenticated;

-- 1. Read the send-email address + secret out of the existing notify triggers
--    (so the secret never has to be pasted anywhere) and back them up.
do $$
declare
  s_pa text; s_po text; s text;
  v_secret text; v_url text; v_app text; v_auth text; v_key text;
  v_extra jsonb := '{}'::jsonb;
begin
  s_pa := pg_get_functiondef('public.trg_pa_notify_configured()'::regprocedure);
  s_po := pg_get_functiondef('public.trg_po_notify_configured()'::regprocedure);
  s := s_pa || E'\n' || s_po;

  insert into public._fn_backup(name, src) values
    ('trg_pa_notify_configured', s_pa), ('trg_po_notify_configured', s_po)
  on conflict (name) do nothing;           -- keep the ORIGINAL on re-runs

  v_secret := coalesce(
    substring(s from $re$'x-email-secret'\s*,\s*'([^']+)'$re$),
    substring(s from $re$"x-email-secret"\s*:\s*"([^"]+)"$re$));
  v_auth := coalesce(
    substring(s from $re$'Authorization'\s*,\s*'([^']+)'$re$),
    substring(s from $re$"Authorization"\s*:\s*"([^"]+)"$re$));
  v_key := coalesce(
    substring(s from $re$'apikey'\s*,\s*'([^']+)'$re$),
    substring(s from $re$"apikey"\s*:\s*"([^"]+)"$re$));
  v_url := coalesce(
    substring(s from $re$(https://[A-Za-z0-9.-]+/functions/v1/send-email)$re$),
    'https://xgptodkasmytddmdnbtb.supabase.co/functions/v1/send-email');
  v_app := coalesce(
    substring(s from $re$(https://[A-Za-z0-9.-]+\.web\.app)$re$),
    'https://opstation-f06c7.web.app');
  if v_auth is not null then v_extra := v_extra || jsonb_build_object('Authorization', v_auth); end if;
  if v_key  is not null then v_extra := v_extra || jsonb_build_object('apikey', v_key); end if;

  if v_secret is null then
    select secret into v_secret from public.email_action_config where id = 1;
  end if;
  if v_secret is null then
    raise exception 'Could not find the x-email-secret in the existing notify triggers. Nothing was changed. Send the output of: select pg_get_functiondef(''public.trg_pa_notify_configured()''::regprocedure);';
  end if;

  insert into public.email_action_config(id, send_url, secret, extra_headers, app_url)
  values (1, v_url, v_secret, v_extra, v_app)
  on conflict (id) do update
     set send_url = excluded.send_url, secret = excluded.secret,
         extra_headers = excluded.extra_headers, app_url = excluded.app_url,
         updated_at = now();
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Tokens + "already emailed" markers
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.email_action_tokens (
  token       text primary key
              default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  kind        text not null check (kind in ('po', 'pa')),
  doc_id      text not null,
  org_id      text not null,
  user_id     text not null,
  email       text not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days',
  used_at     timestamptz,
  used_action text
);
create index if not exists email_action_tokens_doc_idx on public.email_action_tokens(kind, doc_id);
alter table public.email_action_tokens enable row level security;
revoke all on public.email_action_tokens from anon, authenticated;

create table if not exists public.email_doc_sent (
  kind    text not null,
  doc_id  text not null,
  sent_at timestamptz not null default now(),
  primary key (kind, doc_id)
);
alter table public.email_doc_sent enable row level security;
revoke all on public.email_doc_sent from anon, authenticated;

-- Nothing already in the system gets a retro email.
insert into public.email_doc_sent(kind, doc_id)
  select 'pa', id from public.payment_advices on conflict do nothing;
insert into public.email_doc_sent(kind, doc_id)
  select 'po', id from public.purchase_orders where coalesce(is_locked, false) on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Small helpers
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._h(t text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;

create or replace function public._rs(v numeric) returns text
language sql immutable as $$
  select 'Rs ' || case when coalesce(v, 0) = trunc(coalesce(v, 0))
                       then to_char(coalesce(v, 0), 'FM999,999,999,999,990')
                       else to_char(coalesce(v, 0), 'FM999,999,999,999,990.00') end
$$;

create or replace function public._qty(v numeric) returns text
language sql immutable as $$
  select case when coalesce(v, 0) = trunc(coalesce(v, 0))
              then to_char(coalesce(v, 0), 'FM999,999,999,990')
              else rtrim(rtrim(to_char(coalesce(v, 0), 'FM999,999,999,990.000'), '0'), '.') end
$$;

-- Swallows the old triggers' plain email (same signature as net.http_post).
create or replace function public._legacy_email_skip(
  url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
  headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
returns bigint language sql immutable as $$ select 0::bigint $$;

create or replace function public._email_send(p_to text, p_subject text, p_html text, p_text text)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare c public.email_action_config%rowtype;
begin
  select * into c from public.email_action_config where id = 1;
  if not found then return; end if;
  perform net.http_post(
    url     := c.send_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-email-secret', c.secret) || c.extra_headers,
    body    := jsonb_build_object('to', jsonb_build_array(p_to), 'subject', p_subject,
                                  'text', p_text, 'html', p_html)
  );
end $$;

-- Who may act: returns {can_approve, can_reject, user_name}. Mirrors the app:
--   PA approve  = approval flow ON and user listed in org.pa_approvers
--   PA reject   = listed approver or admin
--   PO approve  = admin, or permission report.po_approve.view (global / PO branch)
--   PO reject   = same, and only while org.po_approval_required is ON
create or replace function public._email_actor_rights(p_kind text, p_org text, p_user text, p_branch text)
returns json
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  u record; v_admin boolean; v_on text; v_list text; v_perm boolean;
begin
  select id, name, role into u from public.users
   where id = p_user and org_id = p_org
     and coalesce(is_active, true) = true;
  if not found then
    return json_build_object('can_approve', false, 'can_reject', false);
  end if;
  v_admin := u.role in ('admin', 'masterAdmin', 'superAdmin');

  if p_kind = 'pa' then
    select value into v_on   from public.app_config where org_id = p_org and key = 'org.pa_approval_enabled' limit 1;
    select value into v_list from public.app_config where org_id = p_org and key = 'org.pa_approvers' limit 1;
    v_perm := p_user = any (select trim(x) from unnest(string_to_array(coalesce(v_list, ''), ',')) x);
    return json_build_object(
      'user_name', u.name,
      'can_approve', coalesce(v_on, '') = 'true' and v_perm,
      'can_reject',  v_perm or v_admin);
  else
    select value into v_on from public.app_config where org_id = p_org and key = 'org.po_approval_required' limit 1;
    v_perm := v_admin or exists (
      select 1 from public.user_permissions up
       where up.user_id = p_user and up.permission = 'report.po_approve.view'
         and (up.branch_id is null or up.branch_id = p_branch));
    return json_build_object(
      'user_name', u.name,
      'can_approve', v_perm,
      'can_reject',  v_perm and coalesce(v_on, '') = 'true');
  end if;
end $$;

-- The document as JSON (used for both the email and the confirm page).
create or replace function public._email_doc(p_kind text, p_id text)
returns json
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  a public.payment_advices%rowtype;
  p public.purchase_orders%rowtype;
  v_org text; v_lines json; v_total numeric; v_sup text; v_branch text;
  v_by text; v_rates boolean; v_state text;
begin
  if p_kind = 'pa' then
    select * into a from public.payment_advices where id = p_id;
    if not found then return null; end if;
    select name into v_org from public.orgs where id = a.org_id;
    select coalesce(json_agg(json_build_object(
             'name', l.party_name, 'detail', l.bank_details, 'amount', l.amount_to_pay)
             order by l.line_order), '[]'::json)
      into v_lines from public.payment_advice_lines l where l.advice_id = a.id;
    v_state := case when a.status = 'pending' then 'pending' else a.status end;
    return json_build_object(
      'kind', 'pa', 'id', a.id, 'org_id', a.org_id, 'org_name', v_org,
      'title', 'Payment Advice', 'number', a.advice_number, 'date', a.advice_date,
      'state', v_state, 'note', a.note, 'total', a.grand_total,
      'created_by_name', a.created_by_name, 'created_at', a.created_at,
      'approved_by_name', a.approved_by_name, 'approved_at', a.approved_at,
      'rejected_by_name', a.rejected_by_name, 'rejected_at', a.rejected_at,
      'reject_reason', a.reject_reason,
      'lines', v_lines);
  else
    select * into p from public.purchase_orders where id = p_id;
    if not found then return null; end if;
    select name into v_org from public.orgs where id = p.org_id;
    select name into v_sup from public.suppliers where id = p.supplier_id;
    select name into v_branch from public.branches where id = p.branch_id;
    select name into v_by from public.users where id = coalesce(p.locked_by, p.created_by);
    select coalesce(sum(coalesce(i.quantity_ordered, 0) * coalesce(i.unit_cost, 0)), 0),
           bool_or(coalesce(i.unit_cost, 0) > 0)
      into v_total, v_rates
      from public.purchase_order_items i where i.purchase_order_id = p.id;
    select coalesce(json_agg(json_build_object(
             'name', pr.name, 'sku', pr.sku, 'uom', um.abbreviation,
             'qty', i.quantity_ordered, 'rate', i.unit_cost,
             'amount', coalesce(i.quantity_ordered, 0) * coalesce(i.unit_cost, 0))
             order by pr.name), '[]'::json)
      into v_lines
      from public.purchase_order_items i
      left join public.products pr on pr.id = i.product_id
      left join public.uoms um on um.id = i.uom_id
     where i.purchase_order_id = p.id;
    v_state := case
      when p.voided_at is not null then 'void'
      when p.approved_at is not null then 'approved'
      when not coalesce(p.is_locked, false) and p.rejected_at is not null then 'rejected'
      when not coalesce(p.is_locked, false) then 'draft'
      when coalesce(p.status, '') in ('received', 'partially_received', 'closed') then 'closed'
      else 'pending' end;
    return json_build_object(
      'kind', 'po', 'id', p.id, 'org_id', p.org_id, 'org_name', v_org,
      'branch_id', p.branch_id, 'branch_name', v_branch,
      'title', 'Purchase Order', 'number', p.voucher_number, 'date', p.voucher_date,
      'state', v_state, 'note', p.remarks, 'supplier_name', v_sup,
      'total', v_total, 'show_rates', coalesce(v_rates, false),
      'created_by_name', v_by, 'created_at', coalesce(p.locked_at, p.created_at),
      'approved_by_name', p.approved_by_name, 'approved_at', p.approved_at,
      'rejected_by_name', p.rejected_by_name, 'rejected_at', p.rejected_at,
      'reject_reason', p.reject_reason,
      'lines', v_lines);
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The email itself
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._email_doc_html(d json, p_token text, p_open_url text, p_app text)
returns text
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  is_po boolean := d->>'kind' = 'po';
  rates boolean := coalesce((d->>'show_rates')::boolean, false);
  l json; n int := 0; v_rows text := ''; meta text := ''; btns text; h text;
  v_date text; v_when text; v_detail text;
  c_brand text := '#2F6FED'; c_ink text := '#0F1729'; c_mut text := '#6B7280'; c_rule text := '#E5E7EB';
  td text := 'padding:10px 12px;border-bottom:1px solid #E5E7EB;font-size:13px;color:#0F1729;vertical-align:top;';
  th text := 'padding:8px 12px;background:#F3F5FA;font-size:11px;letter-spacing:.6px;text-transform:uppercase;color:#6B7280;text-align:left;';
begin
  v_date := to_char((d->>'date')::date, 'DD Mon YYYY');
  v_when := to_char(((d->>'created_at')::timestamptz) at time zone 'Asia/Karachi', 'DD Mon YYYY, HH24:MI');

  -- line rows
  for l in select * from json_array_elements(coalesce(d->'lines', '[]'::json)) loop
    n := n + 1;
    if is_po then
      v_rows := v_rows || '<tr>'
        || '<td style="' || td || 'color:#6B7280;width:24px">' || n || '</td>'
        || '<td style="' || td || '"><b>' || _h(l->>'name') || '</b>'
        || case when coalesce(l->>'sku', '') <> '' then '<br><span style="color:#6B7280;font-size:11px">' || _h(l->>'sku') || '</span>' else '' end
        || '</td>'
        || '<td style="' || td || 'text-align:right;white-space:nowrap">' || _qty((l->>'qty')::numeric)
        || case when coalesce(l->>'uom', '') <> '' then ' ' || _h(l->>'uom') else '' end || '</td>'
        || case when rates then
             '<td style="' || td || 'text-align:right;white-space:nowrap">' || _rs((l->>'rate')::numeric) || '</td>'
          || '<td style="' || td || 'text-align:right;white-space:nowrap;font-weight:700">' || _rs((l->>'amount')::numeric) || '</td>'
           else '' end
        || '</tr>';
    else
      v_detail := trim(coalesce(l->>'detail', ''));
      v_rows := v_rows || '<tr>'
        || '<td style="' || td || 'color:#6B7280;width:24px">' || n || '</td>'
        || '<td style="' || td || '"><b>' || _h(l->>'name') || '</b>'
        || case when v_detail <> '' then '<br><span style="color:#6B7280;font-size:12px;line-height:1.45">'
                 || replace(_h(v_detail), E'\n', '<br>') || '</span>' else '' end
        || '</td>'
        || '<td style="' || td || 'text-align:right;white-space:nowrap;font-weight:700">' || _rs((l->>'amount')::numeric) || '</td>'
        || '</tr>';
    end if;
  end loop;

  -- meta chips
  if is_po then
    meta := '<td style="padding:0 16px 0 0;vertical-align:top"><div style="font-size:11px;color:#6B7280;text-transform:uppercase;letter-spacing:.6px">Supplier</div>'
         || '<div style="font-size:14px;font-weight:700;color:#0F1729">' || _h(coalesce(d->>'supplier_name', '—')) || '</div></td>'
         || case when coalesce(d->>'branch_name', '') <> '' then
              '<td style="padding:0 16px 0 0;vertical-align:top"><div style="font-size:11px;color:#6B7280;text-transform:uppercase;letter-spacing:.6px">Branch</div>'
           || '<div style="font-size:14px;font-weight:700;color:#0F1729">' || _h(d->>'branch_name') || '</div></td>' else '' end;
  end if;
  meta := meta
    || '<td style="padding:0 16px 0 0;vertical-align:top"><div style="font-size:11px;color:#6B7280;text-transform:uppercase;letter-spacing:.6px">Date</div>'
    || '<div style="font-size:14px;font-weight:700;color:#0F1729">' || coalesce(v_date, '—') || '</div></td>'
    || '<td style="vertical-align:top"><div style="font-size:11px;color:#6B7280;text-transform:uppercase;letter-spacing:.6px">Lines</div>'
    || '<div style="font-size:14px;font-weight:700;color:#0F1729">' || n || '</div></td>';

  -- buttons
  if p_token is not null then
    btns := '<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto"><tr>'
      || '<td style="padding:0 6px"><a href="' || p_app || '/#/act/' || p_token || '?a=approve" '
      || 'style="display:inline-block;background:#16A34A;color:#ffffff;text-decoration:none;font-weight:700;font-size:15px;padding:13px 30px;border-radius:8px">&#10003;&nbsp; Approve</a></td>'
      || '<td style="padding:0 6px"><a href="' || p_app || '/#/act/' || p_token || '?a=reject" '
      || 'style="display:inline-block;background:#DC2626;color:#ffffff;text-decoration:none;font-weight:700;font-size:15px;padding:13px 30px;border-radius:8px">&#10005;&nbsp; Reject</a></td>'
      || '</tr></table>'
      || '<div style="text-align:center;margin-top:14px"><a href="' || p_open_url || '" '
      || 'style="display:inline-block;color:' || c_brand || ';text-decoration:none;font-weight:700;font-size:13px;padding:9px 20px;border:1.5px solid ' || c_brand || ';border-radius:8px">Go to screen (to edit)</a></div>'
      || '<div style="text-align:center;margin-top:12px;font-size:11.5px;color:#6B7280;line-height:1.5">'
      || 'Approve / Reject opens a confirmation page — nothing changes until you press Confirm.<br>'
      || 'This link is personal to you, works once and expires in 7 days.</div>';
  else
    btns := '<div style="text-align:center"><a href="' || p_open_url || '" '
      || 'style="display:inline-block;background:' || c_brand || ';color:#ffffff;text-decoration:none;font-weight:700;font-size:15px;padding:13px 30px;border-radius:8px">Open in Opstation</a></div>';
  end if;

  h := '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>'
    || '<body style="margin:0;padding:0;background:#F3F5FA;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif">'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F3F5FA"><tr><td align="center" style="padding:24px 12px">'
    || '<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #E5E7EB">'
    -- header band
    || '<tr><td style="background:' || c_brand || ';padding:22px 24px;color:#ffffff">'
    ||   '<div style="font-size:11px;letter-spacing:1.6px;font-weight:800;opacity:.85">' || upper(_h(d->>'org_name')) || '</div>'
    ||   '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:6px"><tr>'
    ||   '<td style="color:#ffffff"><div style="font-size:22px;font-weight:800">' || _h(d->>'title') || '</div>'
    ||   '<div style="font-size:13px;opacity:.9;margin-top:2px">' || _h(d->>'number') || '</div></td>'
    ||   '<td align="right" style="vertical-align:top"><span style="display:inline-block;background:#FEF3C7;color:#92400E;font-size:10.5px;font-weight:800;letter-spacing:.8px;padding:5px 10px;border-radius:20px">AWAITING APPROVAL</span></td>'
    ||   '</tr></table></td></tr>'
    -- intro
    || '<tr><td style="padding:18px 24px 4px;font-size:13.5px;color:#374151;line-height:1.5">'
    ||   'Submitted by <b>' || _h(coalesce(d->>'created_by_name', '—')) || '</b>'
    ||   case when v_when is not null then ' on ' || v_when else '' end || '.'
    || '</td></tr>'
    -- meta
    || '<tr><td style="padding:12px 24px"><table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background:#F9FAFB;border:1px solid #E5E7EB;border-radius:10px"><tr><td style="padding:12px 14px">'
    ||   '<table role="presentation" cellpadding="0" cellspacing="0"><tr>' || meta || '</tr></table>'
    || '</td></tr></table></td></tr>'
    -- lines
    || '<tr><td style="padding:6px 24px 0"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #E5E7EB;border-radius:10px;border-collapse:separate;overflow:hidden">'
    ||   '<tr><th style="' || th || '">#</th>'
    ||   case when is_po then
           '<th style="' || th || '">Item</th><th style="' || th || 'text-align:right">Qty</th>'
           || case when rates then '<th style="' || th || 'text-align:right">Rate</th><th style="' || th || 'text-align:right">Amount</th>' else '' end
         else '<th style="' || th || '">Pay to</th><th style="' || th || 'text-align:right">Amount</th>' end
    ||   '</tr>' || v_rows
    || '</table></td></tr>'
    -- total
    || case when (not is_po) or rates then
         '<tr><td style="padding:14px 24px 0"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#EEF3FE;border-radius:10px"><tr>'
      || '<td style="padding:14px 16px;font-size:12px;font-weight:800;letter-spacing:1px;color:#0F1729">' || case when is_po then 'PO TOTAL' else 'TOTAL TO PAY' end || '</td>'
      || '<td align="right" style="padding:14px 16px;font-size:20px;font-weight:800;color:' || c_brand || '">' || _rs((d->>'total')::numeric) || '</td>'
      || '</tr></table></td></tr>' else '' end
    -- note
    || case when coalesce(trim(d->>'note'), '') <> '' then
         '<tr><td style="padding:14px 24px 0"><div style="border-left:3px solid ' || c_brand || ';background:#F9FAFB;padding:10px 12px;font-size:13px;color:#374151;line-height:1.5">'
      || '<b>' || case when is_po then 'Remarks' else 'Note' end || ':</b> ' || replace(_h(trim(d->>'note')), E'\n', '<br>') || '</div></td></tr>' else '' end
    -- buttons
    || '<tr><td style="padding:26px 24px 24px">' || btns || '</td></tr>'
    -- footer
    || '<tr><td style="background:#F9FAFB;border-top:1px solid #E5E7EB;padding:14px 24px;font-size:11px;color:#9CA3AF;text-align:center">'
    ||   'Sent by Opstation for ' || _h(d->>'org_name') || '. You are receiving this because you are on the approval notification list.'
    || '</td></tr>'
    || '</table></td></tr></table></body></html>';
  return h;
end $$;

-- Sends the email for one document to every configured address.
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Triggers
-- ─────────────────────────────────────────────────────────────────────────────
-- PO: when it is submitted (locked) and still needs approval.
create or replace function public.trg_po_email_rich()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  begin
    if coalesce(NEW.is_locked, false)
       and (TG_OP = 'INSERT' or not coalesce(OLD.is_locked, false))
       and NEW.approved_at is null and NEW.voided_at is null then
      delete from public.email_doc_sent where kind = 'po' and doc_id = NEW.id;  -- a re-submission emails again
      perform public._email_doc_notify('po', NEW.id);
    end if;
  exception when others then null;
  end;
  return NEW;
end $$;

drop trigger if exists po_email_rich on public.purchase_orders;
create trigger po_email_rich
  after insert or update of is_locked on public.purchase_orders
  for each row execute function public.trg_po_email_rich();

-- PA: the header is saved first and the lines right after, so the email goes
-- out when the lines land. A header going back to 'pending' re-arms it.
create or replace function public.trg_pa_email_rearm()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  if NEW.status = 'pending' and coalesce(OLD.status, '') <> 'pending' then
    delete from public.email_doc_sent where kind = 'pa' and doc_id = NEW.id;
  end if;
  return NEW;
end $$;

drop trigger if exists pa_email_rearm on public.payment_advices;
create trigger pa_email_rearm
  after update of status on public.payment_advices
  for each row execute function public.trg_pa_email_rearm();

create or replace function public.trg_pa_lines_email_rich()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare v_id text;
begin
  begin
    for v_id in select distinct advice_id from new_rows loop
      if exists (select 1 from public.payment_advices where id = v_id and status = 'pending') then
        perform public._email_doc_notify('pa', v_id);
      end if;
    end loop;
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists pa_lines_email_rich on public.payment_advice_lines;
create trigger pa_lines_email_rich
  after insert on public.payment_advice_lines
  referencing new table as new_rows
  for each statement execute function public.trg_pa_lines_email_rich();

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Confirm page RPCs (no login — the token is the key)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.email_action_info(p_token text)
returns json
language plpgsql stable security definer set search_path to 'public'
as $$
declare t public.email_action_tokens%rowtype; d json; r json;
begin
  if p_token is null or length(p_token) < 32 then
    return json_build_object('ok', false, 'error', 'not_found');
  end if;
  select * into t from public.email_action_tokens where token = p_token;
  if not found then return json_build_object('ok', false, 'error', 'not_found'); end if;
  d := public._email_doc(t.kind, t.doc_id);
  if d is null then return json_build_object('ok', false, 'error', 'doc_gone'); end if;
  r := public._email_actor_rights(t.kind, t.org_id, t.user_id, d->>'branch_id');
  return json_build_object(
    'ok', true,
    'doc', d,
    'user_name', r->>'user_name',
    'can_approve', coalesce((r->>'can_approve')::boolean, false),
    'can_reject',  coalesce((r->>'can_reject')::boolean, false),
    'used_at', t.used_at, 'used_action', t.used_action,
    'expired', t.expires_at < now());
end $$;

create or replace function public.email_action_do(p_token text, p_action text, p_reason text default null)
returns json
language plpgsql security definer set search_path to 'public'
as $$
declare
  t public.email_action_tokens%rowtype; d json; r json;
  v_name text; v_now timestamptz := now(); v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_sig text; v_stamp text; v_details text;
begin
  select * into t from public.email_action_tokens where token = p_token for update;
  if not found then return json_build_object('ok', false, 'error', 'not_found'); end if;
  if t.used_at is not null then return json_build_object('ok', false, 'error', 'used'); end if;
  if t.expires_at < v_now then return json_build_object('ok', false, 'error', 'expired'); end if;
  if p_action not in ('approve', 'reject') then return json_build_object('ok', false, 'error', 'bad_action'); end if;
  if p_action = 'reject' and v_reason is null then return json_build_object('ok', false, 'error', 'reason_required'); end if;

  -- lock the document, then re-check its state and the user's rights NOW
  if t.kind = 'pa' then
    perform 1 from public.payment_advices where id = t.doc_id for update;
  else
    perform 1 from public.purchase_orders where id = t.doc_id for update;
  end if;
  d := public._email_doc(t.kind, t.doc_id);
  if d is null then return json_build_object('ok', false, 'error', 'doc_gone'); end if;
  if d->>'state' <> 'pending' then
    return json_build_object('ok', false, 'error', 'not_pending', 'doc', d);
  end if;
  r := public._email_actor_rights(t.kind, t.org_id, t.user_id, d->>'branch_id');
  if not coalesce((r->>(case when p_action = 'approve' then 'can_approve' else 'can_reject' end))::boolean, false) then
    return json_build_object('ok', false, 'error', 'no_permission');
  end if;
  v_name := r->>'user_name';

  if t.kind = 'pa' then
    if p_action = 'approve' then
      select nullif(trim(signature_url), '') into v_sig from public.users where id = t.user_id;
      select nullif(trim(value), '') into v_stamp from public.app_config
       where org_id = t.org_id and key = 'org.stamp_url' limit 1;
      update public.payment_advices
         set status = 'approved', approved_by = t.user_id, approved_by_name = v_name,
             approved_at = v_now, approved_signature_url = v_sig, approved_stamp_url = v_stamp,
             updated_at = v_now
       where id = t.doc_id;
      v_details := 'Approved by ' || coalesce(v_name, '') || ' (via email)';
    else
      update public.payment_advices
         set status = 'rejected', rejected_by = t.user_id, rejected_by_name = v_name,
             rejected_at = v_now, reject_reason = v_reason, updated_at = v_now
       where id = t.doc_id;
      v_details := 'Rejected (via email): ' || v_reason;
    end if;
  else
    if p_action = 'approve' then
      update public.purchase_orders
         set approved_by = t.user_id, approved_by_name = v_name, approved_at = v_now, updated_at = v_now
       where id = t.doc_id;
      v_details := 'Approved by ' || coalesce(v_name, '') || ' (via email)';
    else
      update public.purchase_orders
         set rejected_at = v_now, rejected_by = t.user_id, rejected_by_name = v_name,
             reject_reason = v_reason, reject_ack_at = null, reject_ack_by = null,
             is_locked = false, locked_by = null, locked_at = null, status = 'draft',
             updated_at = v_now
       where id = t.doc_id;
      v_details := 'Rejected by ' || coalesce(v_name, '') || ' (via email): ' || v_reason;
    end if;
  end if;

  begin
    insert into public.voucher_audit_log(id, org_id, voucher_id, voucher_type, action, details, performed_by, performed_at)
    values ('val_' || (extract(epoch from clock_timestamp()) * 1000000)::bigint, t.org_id, t.doc_id,
            upper(t.kind), case when p_action = 'approve' then 'approved' else 'rejected' end,
            v_details, t.user_id, v_now);
  exception when others then null;
  end;

  -- this link is spent; the other recipients' links now show "already decided"
  update public.email_action_tokens set used_at = v_now, used_action = p_action where token = p_token;

  return json_build_object('ok', true, 'doc', public._email_doc(t.kind, t.doc_id));
end $$;

revoke all on function public.email_action_info(text) from public;
revoke all on function public.email_action_do(text, text, text) from public;
grant execute on function public.email_action_info(text) to anon, authenticated;
grant execute on function public.email_action_do(text, text, text) to anon, authenticated;
revoke all on function public._email_send(text, text, text, text) from public, anon, authenticated;
revoke all on function public._email_doc_notify(text, text) from public, anon, authenticated;
revoke all on function public._email_doc(text, text) from public, anon, authenticated;
revoke all on function public._email_doc_html(json, text, text, text) from public, anon, authenticated;
revoke all on function public._email_actor_rights(text, text, text, text) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Switch off the OLD plain email inside the existing notify triggers
--    (their push part keeps working exactly as before). Done last, so if
--    anything above failed the old emails are still going out.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare f text; src text; n_http int; n_mail int;
begin
  foreach f in array array['trg_pa_notify_configured', 'trg_po_notify_configured'] loop
    src := pg_get_functiondef(('public.' || f || '()')::regprocedure);
    select count(*) into n_http from regexp_matches(src, '\m(net\.|extensions\.)?http_post\s*\(', 'g');
    if n_http = 0 then
      if position('_legacy_email_skip' in src) > 0 then continue; end if;   -- already switched off
      raise exception '% sends email some other way — nothing was changed. Send me its definition.', f;
    end if;
    select count(*) into n_mail from regexp_matches(src, 'send-email', 'g');
    if n_mail = 0 or n_http > n_mail then
      raise exception '% calls http_post for something other than send-email — nothing was changed. Send me its definition.', f;
    end if;
    execute regexp_replace(src, '\m(net\.|extensions\.)?http_post\s*\(', 'public._legacy_email_skip(', 'g');
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- REVERT (only if ever needed): restores the original plain emails and stops
-- the rich ones.
--   do $$ declare b record; begin
--     for b in select src from public._fn_backup loop execute b.src; end loop; end $$;
--   drop trigger if exists po_email_rich on public.purchase_orders;
--   drop trigger if exists pa_lines_email_rich on public.payment_advice_lines;
-- ─────────────────────────────────────────────────────────────────────────────
