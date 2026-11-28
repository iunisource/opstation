-- 296 — Notifications centre: the master admin decides who is told about what.
--
--   * One rule per (event, recipient): push (browser + bell) and/or email,
--     limited to chosen branches. Recipients can be any user, the
--     document's creator, or an outside email address (email only).
--   * NOBODY is included by default — every event is silent until the master
--     admin adds recipients (Admin Settings → Notifications).
--   * All the old hard-wired notification triggers ("all admins", PO/PA notify
--     lists, duplicate pushes) are replaced by one dispatcher, notify_event().
--   * PO and PA emails keep their rich format with Approve / Reject.
--   * Untouched: the on-screen alerts (PO rejection banner, Job Cards, Stock
--     Transfers), the menu pendency counters, and the scheduled jobs
--     (attendance summary email, reminders, backup).
--
-- Run the WHOLE file once. Safe to run again.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Tables
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.notification_rules (
  id          text primary key default ('nr_' || replace(gen_random_uuid()::text, '-', '')),
  org_id      text not null,
  event_key   text not null,
  user_id     text,                 -- users.id, or '__creator__' (the document's creator)
  email       text,                 -- outside address (email only)
  push        boolean not null default true,
  email_on    boolean not null default false,
  branch_ids  text[],               -- null = all branches
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (user_id is not null or email is not null)
);
create unique index if not exists notification_rules_uq
  on public.notification_rules(org_id, event_key, coalesce(user_id, ''), coalesce(lower(email), ''));
create index if not exists notification_rules_evt on public.notification_rules(org_id, event_key);

create table if not exists public.notification_event_state (
  org_id    text not null,
  event_key text not null,
  enabled   boolean not null default true,
  primary key (org_id, event_key)
);

-- Only the org's master admin (or super admin) may read / change the rules.
create or replace function public._is_org_master(p_org text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.users u
     where u.org_id = p_org
       and u.role in ('masterAdmin', 'superAdmin')
       and coalesce(u.is_active, true)
       and (u.account_id = public.current_account_id()
            or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))));
$$;

alter table public.notification_rules enable row level security;
alter table public.notification_event_state enable row level security;
drop policy if exists nr_master on public.notification_rules;
create policy nr_master on public.notification_rules for all to authenticated
  using (public._is_org_master(org_id)) with check (public._is_org_master(org_id));
drop policy if exists nes_master on public.notification_event_state;
create policy nes_master on public.notification_event_state for all to authenticated
  using (public._is_org_master(org_id)) with check (public._is_org_master(org_id));
grant select, insert, update, delete on public.notification_rules, public.notification_event_state to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Emails
-- ─────────────────────────────────────────────────────────────────────────────
-- Rich PO / PA email (unchanged design) to an explicit list of addresses.
create or replace function public._email_doc_send(p_kind text, p_id text, p_emails text[])
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare
  d json; v_org text; v_app text; v_open text;
  v_email text; v_uid text; v_rights json; v_token text; v_subj text; v_text text;
begin
  d := public._email_doc(p_kind, p_id);
  if d is null or d->>'state' <> 'pending' then return; end if;
  v_org := d->>'org_id';

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

  foreach v_email in array coalesce(p_emails, '{}') loop
    begin
      v_token := null; v_uid := null;
      select id into v_uid from public.users
       where org_id = v_org and lower(email) = lower(v_email) and coalesce(is_active, true)
       limit 1;
      if v_uid is not null then
        v_rights := public._email_actor_rights(p_kind, v_org, v_uid, d->>'branch_id');
        if coalesce((v_rights->>'can_approve')::boolean, false) or coalesce((v_rights->>'can_reject')::boolean, false) then
          insert into public.email_action_tokens(kind, doc_id, org_id, user_id, email)
          values (p_kind, p_id, v_org, v_uid, lower(v_email))
          returning token into v_token;
        end if;
      end if;
      perform public._email_send(lower(v_email), v_subj,
                                 public._email_doc_html(d, v_token, v_open, v_app), v_text);
    exception when others then null;
    end;
  end loop;
end $$;

-- Simple branded email for every other event.
create or replace function public._email_simple_html(p_org_name text, p_title text, p_body text, p_url text)
returns text
language sql immutable as $$
  select '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>'
    || '<body style="margin:0;padding:0;background:#F3F5FA;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif">'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F3F5FA"><tr><td align="center" style="padding:24px 12px">'
    || '<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="width:100%;max-width:560px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #E5E7EB">'
    || '<tr><td style="background:#2F6FED;padding:18px 22px;color:#ffffff">'
    ||   '<div style="font-size:11px;letter-spacing:1.6px;font-weight:800;opacity:.85">' || upper(public._h(coalesce(p_org_name, ''))) || '</div>'
    ||   '<div style="font-size:19px;font-weight:800;margin-top:4px">' || public._h(p_title) || '</div></td></tr>'
    || '<tr><td style="padding:20px 22px;font-size:14px;color:#0F1729;line-height:1.55">' || replace(public._h(coalesce(p_body, '')), E'\n', '<br>') || '</td></tr>'
    || '<tr><td style="padding:4px 22px 24px"><a href="' || p_url || '" style="display:inline-block;background:#2F6FED;color:#ffffff;text-decoration:none;font-weight:700;font-size:14px;padding:11px 24px;border-radius:8px">Open in Opstation</a></td></tr>'
    || '<tr><td style="background:#F9FAFB;border-top:1px solid #E5E7EB;padding:12px 22px;font-size:11px;color:#9CA3AF">'
    ||   'Sent by Opstation. Your notification settings are managed by your organization''s master admin.</td></tr>'
    || '</table></td></tr></table></body></html>'
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The dispatcher
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.notify_event(
  p_org text, p_event text, p_branch text, p_creator text,
  p_title text, p_body text, p_path text,
  p_rich_kind text default null, p_doc_id text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_push text[]; v_emails text[]; v_notif text; v_org_name text; v_app text; e text;
begin
  if p_org is null then return; end if;
  if exists (select 1 from public.notification_event_state
              where org_id = p_org and event_key = p_event and not enabled) then
    return;
  end if;

  -- Push recipients (active users of this org).
  select array_agg(distinct x.uid) into v_push
    from (select case when r.user_id = '__creator__' then p_creator else r.user_id end as uid
            from public.notification_rules r
           where r.org_id = p_org and r.event_key = p_event and r.push and r.user_id is not null
             and (r.branch_ids is null or p_branch is null or p_branch = any (r.branch_ids))) x
    join public.users u on u.id = x.uid and u.org_id = p_org and coalesce(u.is_active, true)
   where x.uid is not null;

  if v_push is not null and array_length(v_push, 1) > 0 then
    begin
      perform public.push_send(p_org, v_push, p_title, p_body, p_path);
    exception when others then null;
    end;
    begin
      insert into public.notifications
        (org_id, title, body, audience, audience_roles, link_url, created_by, origin)
      values (p_org, p_title, p_body, 'roles', '{}'::text[], nullif(p_path, ''), v_push[1], 'system')
      returning id::text into v_notif;
      insert into public.notification_recipients (notification_id, recipient_user_id)
      select v_notif, unnest(v_push);
    exception when others then null;
    end;
  end if;

  -- Email recipients.
  select array_agg(distinct lower(trim(x.addr))) into v_emails
    from (select case
                   when r.email is not null then r.email
                   when r.user_id = '__creator__' then (select u.email from public.users u where u.id = p_creator)
                   else (select u.email from public.users u
                          where u.id = r.user_id and u.org_id = p_org and coalesce(u.is_active, true))
                 end as addr
            from public.notification_rules r
           where r.org_id = p_org and r.event_key = p_event and r.email_on
             and (r.branch_ids is null or p_branch is null or p_branch = any (r.branch_ids))) x
   where x.addr like '%@%';

  if v_emails is not null and array_length(v_emails, 1) > 0 then
    if p_rich_kind in ('po', 'pa') and p_doc_id is not null then
      perform public._email_doc_send(p_rich_kind, p_doc_id, v_emails);
    else
      select name into v_org_name from public.orgs where id = p_org;
      select app_url into v_app from public.email_action_config where id = 1;
      v_app := coalesce(v_app, 'https://opstation-f06c7.web.app');
      foreach e in array v_emails loop
        begin
          perform public._email_send(e, p_title || coalesce(' · ' || nullif(v_org_name, ''), ''),
            public._email_simple_html(v_org_name, p_title, p_body, v_app || '/#' || coalesce(p_path, '/')),
            p_title || E'\n' || coalesce(p_body, '') || E'\n\nOpen: ' || v_app || '/#' || coalesce(p_path, '/'));
        exception when others then null;
        end;
      end loop;
    end if;
  end if;
end $$;
revoke all on function public.notify_event(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;

-- Tiny helpers for the triggers.
create or replace function public._cfg_on(p_org text, p_key text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select value from public.app_config where org_id = p_org and key = p_key limit 1), '') = 'true';
$$;
create or replace function public._became(n jsonb, o jsonb, p_field text, p_value text)
returns boolean language sql immutable as $$
  select coalesce(n->>p_field, '') = p_value and coalesce(o->>p_field, '') is distinct from p_value;
$$;
create or replace function public._became_locked(n jsonb, o jsonb)
returns boolean language sql immutable as $$
  select coalesce((n->>'is_locked')::boolean, false) and not coalesce((o->>'is_locked')::boolean, false);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. One trigger function for every document table
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.trg_notify_events()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare
  n jsonb := to_jsonb(NEW);
  o jsonb := case when TG_OP = 'UPDATE' then to_jsonb(OLD) else '{}'::jsonb end;
  v_org text := n->>'org_id';
  v_id text := n->>'id';
  v_br text := n->>'branch_id';
  v_by text := n->>'created_by';
  v_num text := coalesce(n->>'voucher_number', n->>'advice_number', n->>'entry_number', '');
  v_sup text; v_amt text;
begin
  begin
    if v_org is null then return NEW; end if;

    if TG_TABLE_NAME = 'purchase_orders' then
      -- Submitted for approval
      if _became_locked(n, o) and n->>'approved_at' is null and n->>'voided_at' is null
         and _cfg_on(v_org, 'org.po_approval_required') then
        select name into v_sup from suppliers where id = n->>'supplier_id';
        select _rs(coalesce(sum(coalesce(quantity_ordered, 0) * coalesce(unit_cost, 0)), 0)) into v_amt
          from purchase_order_items where purchase_order_id = v_id;
        perform notify_event(v_org, 'po_submitted', v_br, v_by, 'Purchase Order pending approval',
          v_num || coalesce(' · ' || v_sup, '') || case when v_amt <> 'Rs 0' then ' · ' || v_amt else '' end,
          '/erp/purchase?focus=' || v_id, 'po', v_id);
      end if;
      -- Approved
      if n->>'approved_at' is not null and o->>'approved_at' is null and TG_OP = 'UPDATE' then
        perform notify_event(v_org, 'po_approved', v_br, v_by, 'Purchase Order approved',
          v_num || ' approved' || coalesce(' by ' || nullif(n->>'approved_by_name', ''), ''),
          '/erp/purchase?focus=' || v_id);
      end if;
      -- Rejected
      if n->>'rejected_at' is not null and (n->>'rejected_at') is distinct from (o->>'rejected_at') then
        perform notify_event(v_org, 'po_rejected', v_br, v_by, 'Purchase Order rejected',
          v_num || ' rejected' || coalesce(' by ' || nullif(n->>'rejected_by_name', ''), '')
                || coalesce(': ' || nullif(n->>'reject_reason', ''), ''),
          '/erp/purchase?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'payment_advices' then
      if TG_OP = 'UPDATE' and coalesce(o->>'status', '') = 'pending' then
        if _became(n, o, 'status', 'approved') then
          perform notify_event(v_org, 'pa_approved', null, v_by, 'Payment Advice approved',
            v_num || ' approved' || coalesce(' by ' || nullif(n->>'approved_by_name', ''), ''),
            '/financials/payment-advice?focus=' || v_id);
        elsif _became(n, o, 'status', 'rejected') then
          perform notify_event(v_org, 'pa_rejected', null, v_by, 'Payment Advice rejected',
            v_num || ' rejected' || coalesce(' by ' || nullif(n->>'rejected_by_name', ''), '')
                  || coalesce(': ' || nullif(n->>'reject_reason', ''), ''),
            '/financials/payment-advice?focus=' || v_id);
        end if;
      end if;

    elsif TG_TABLE_NAME = 'purchase_grns' then
      if coalesce(o->>'status', 'draft') = 'draft' and coalesce(n->>'status', 'draft') <> 'draft'
         and not coalesce((n->>'is_voided')::boolean, false) then
        if _cfg_on(v_org, 'org.grn_supervise_flow') and n->>'supervised_at' is null then
          perform notify_event(v_org, 'grn_supervise', v_br, v_by, 'GRN needs supervision', v_num,
            '/erp/grn?focus=' || v_id);
        end if;
        perform notify_event(v_org, 'grn_ready_invoice', v_br, v_by, 'GRN received — ready to invoice', v_num,
          '/erp/grn?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME in ('purchase_invoices', 'purchase_return_invoices', 'sales_invoices') then
      declare
        k text := case TG_TABLE_NAME when 'purchase_invoices' then 'pi'
                                     when 'purchase_return_invoices' then 'pri' else 'si' end;
        lbl text := case TG_TABLE_NAME when 'purchase_invoices' then 'Purchase Invoice'
                                       when 'purchase_return_invoices' then 'Purchase Return Invoice' else 'Sales Invoice' end;
        pth text := case TG_TABLE_NAME when 'purchase_invoices' then '/erp/purchase-invoices?focus='
                                       when 'purchase_return_invoices' then '/erp/purchase-return-vouchers?focus='
                                       else '/erp/sales-invoices?focus=' end || v_id;
        amt text := case when n ? 'grand_total' then ' · ' || _rs((n->>'grand_total')::numeric) else '' end;
      begin
        if _became(n, o, 'review_status', 'pending') then
          perform notify_event(v_org, k || '_review', v_br, v_by, lbl || ' needs review', v_num || amt, pth);
        elsif _became(n, o, 'review_status', 'rejected') then
          perform notify_event(v_org, k || '_review_rejected', v_br, v_by, lbl || ' review rejected',
            v_num || coalesce(' — ' || nullif(n->>'review_reason', ''), ''), pth);
        end if;
        if k in ('pi', 'si') and _became_locked(n, o) and n->>'supervised_at' is null
           and not coalesce((n->>'is_voided')::boolean, false)
           and _cfg_on(v_org, 'org.' || k || '_supervise_flow') then
          perform notify_event(v_org, k || '_supervise', v_br, v_by, lbl || ' needs supervision', v_num || amt, pth);
        end if;
      end;

    elsif TG_TABLE_NAME = 'sales_return_invoices' then
      if _became_locked(n, o) and n->>'supervised_at' is null
         and not coalesce((n->>'is_voided')::boolean, false)
         and _cfg_on(v_org, 'org.sri_supervise_flow') then
        perform notify_event(v_org, 'sri_supervise', v_br, v_by, 'Sales Return Invoice needs supervision', v_num,
          '/erp/sales-return-invoices');
      end if;

    elsif TG_TABLE_NAME = 'delivery_orders' then
      if (_became_locked(n, o) or _became(n, o, 'status', 'saved')) and n->>'supervised_at' is null
         and not coalesce((n->>'is_voided')::boolean, false)
         and _cfg_on(v_org, 'org.do_supervise_flow') then
        perform notify_event(v_org, 'do_supervise', v_br, v_by, 'Delivery Order needs supervision', v_num,
          '/erp/delivery-orders?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'journal_entries' then
      if coalesce(n->>'reference_type', '') = 'jv' then
        if _became(n, o, 'approval_status', 'pending') then
          perform notify_event(v_org, 'jv_approval', v_br, v_by, 'Journal Voucher needs approval', v_num,
            '/financials/journal-vouchers');
        end if;
        if _became(n, o, 'status', 'posted') and n->>'supervised_at' is null
           and _cfg_on(v_org, 'org.jv_supervise_flow') then
          perform notify_event(v_org, 'jv_supervise', v_br, v_by, 'Journal Voucher needs supervision', v_num,
            '/financials/journal-vouchers');
        end if;
      end if;

    elsif TG_TABLE_NAME = 'field_orders' then
      if _became(n, o, 'status', 'submitted') then
        perform notify_event(v_org, 'field_order', v_br, v_by, 'Field order submitted',
          coalesce(nullif(v_num, ''), nullif(n->>'order_number', ''), 'New field order'), '/erp/field-orders');
      end if;

    elsif TG_TABLE_NAME = 'retailer_orders' then
      if _became(n, o, 'status', 'submitted') then
        perform notify_event(v_org, 'retailer_order', v_br, v_by, 'Retailer order received',
          coalesce(nullif(v_num, ''), nullif(n->>'order_number', ''), 'New retailer order'), '/erp/retailer-orders');
      end if;

    elsif TG_TABLE_NAME = 'customers' then
      if TG_OP = 'INSERT' and n->>'supervised_at' is null and _cfg_on(v_org, 'org.customer_supervise_flow') then
        perform notify_event(v_org, 'customer_supervise', null, v_by, 'New customer needs supervision',
          coalesce(n->>'shop_name', n->>'name', ''), '/customers?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'products' then
      if TG_OP = 'INSERT' and n->>'supervised_at' is null and _cfg_on(v_org, 'org.product_supervise_flow') then
        perform notify_event(v_org, 'product_supervise', null, v_by, 'New product needs supervision',
          coalesce(n->>'name', ''), '/erp/products?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'stock_transfers' then
      if _became(n, o, 'status', 'in_transit') then
        perform notify_event(v_org, 'transfer_dispatch', n->>'to_branch_id', v_by, 'Stock transfer to receive',
          v_num || ' — awaiting receipt at your branch', '/erp/stock-transfers?focus=' || v_id);
      end if;
    end if;
  exception when others then
    null;  -- a notification must never block saving a document
  end;
  return NEW;
end $$;

-- Payment Advice "pending": lines are saved right after the header, so the
-- notification (and its rich email) goes out when the lines land — once per
-- submission (email_doc_sent, re-armed when the advice goes back to pending).
create or replace function public.trg_pa_lines_email_rich()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare a record;
begin
  begin
    for a in select pa.* from public.payment_advices pa
              where pa.id in (select distinct advice_id from new_rows) and pa.status = 'pending'
    loop
      insert into public.email_doc_sent(kind, doc_id) values ('pa', a.id) on conflict do nothing;
      if found then
        perform public.notify_event(a.org_id, 'pa_pending', null, a.created_by,
          'Payment Advice pending approval',
          coalesce(a.advice_number, '') || ' · ' || public._rs(a.grand_total)
            || coalesce(' · by ' || nullif(a.created_by_name, ''), ''),
          '/financials/payment-advice?focus=' || a.id, 'pa', a.id);
      end if;
    end loop;
  exception when others then null;
  end;
  return null;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Swap the triggers: old hard-wired ones out, the dispatcher in
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare t record; tbl text;
begin
  for t in select * from (values
      ('purchase_orders', 'push_new_po'), ('purchase_orders', 'trg_notify_po'),
      ('purchase_orders', 'trg_po_notify_configured'), ('purchase_orders', 'po_rejected_push'),
      ('purchase_orders', 'po_email_rich'),
      ('payment_advices', 'pa_notify_configured'),
      ('purchase_grns', 'trg_notify_grn'),
      ('purchase_invoices', 'push_pi_review'), ('purchase_invoices', 'trg_notify_pi'),
      ('purchase_return_invoices', 'push_pri_review'), ('purchase_return_invoices', 'trg_notify_pri'),
      ('sales_invoices', 'push_si_review'), ('sales_invoices', 'trg_notify_si'),
      ('field_orders', 'trg_notify_fo'), ('retailer_orders', 'trg_notify_ro'),
      ('customers', 'trg_notify_customer_supervise'),
      ('stock_transfers', 'push_transfer_dispatch')) v(tbl, trg)
  loop
    if to_regclass('public.' || t.tbl) is not null then
      execute format('drop trigger if exists %I on public.%I', t.trg, t.tbl);
    end if;
  end loop;

  foreach tbl in array array['purchase_orders', 'payment_advices', 'purchase_grns', 'purchase_invoices',
                             'purchase_return_invoices', 'sales_invoices', 'sales_return_invoices',
                             'delivery_orders', 'journal_entries', 'field_orders', 'retailer_orders',
                             'customers', 'products', 'stock_transfers'] loop
    if to_regclass('public.' || tbl) is not null then
      execute format('drop trigger if exists zz_notify_events on public.%I', tbl);
      execute format('create trigger zz_notify_events after insert or update on public.%I
                      for each row execute function public.trg_notify_events()', tbl);
    end if;
  end loop;
end $$;

-- (pa_lines_email_rich on payment_advice_lines and pa_email_rearm on
--  payment_advices from 293 stay — they now route through notify_event.)
