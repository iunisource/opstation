-- 437 — "Talk to our team" enquiries from the website.
--
-- The public website form calls submit_enquiry() (no login needed). Each
-- enquiry is saved here and emailed to the Opstation team. Super admins see
-- and work them in the web panel (Enquiries).
--
-- Name and contact number are required; business name and industry optional.
-- Repeat submits of the same number within 10 minutes are ignored, and the
-- form is throttled if it is flooded. Safe to run again.

create table if not exists public.sales_enquiries (
  id            text primary key default ('enq_' || replace(gen_random_uuid()::text, '-', '')),
  name          text not null,
  phone         text not null,
  business_name text,
  industry      text,
  source        text,
  status        text not null default 'new' check (status in ('new', 'contacted', 'closed')),
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists sales_enquiries_created_idx on public.sales_enquiries (created_at desc);
create index if not exists sales_enquiries_phone_idx   on public.sales_enquiries (phone, created_at desc);

alter table public.sales_enquiries enable row level security;
revoke all on public.sales_enquiries from anon;

drop policy if exists se_read on public.sales_enquiries;
create policy se_read on public.sales_enquiries for select using (public._is_super_admin());
drop policy if exists se_update on public.sales_enquiries;
create policy se_update on public.sales_enquiries for update
  using (public._is_super_admin()) with check (public._is_super_admin());
drop policy if exists se_delete on public.sales_enquiries;
create policy se_delete on public.sales_enquiries for delete using (public._is_super_admin());
grant select, update, delete on public.sales_enquiries to authenticated;

create or replace function public.submit_enquiry(
  p_name text, p_phone text,
  p_business text default null, p_industry text default null, p_source text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_name text := left(btrim(coalesce(p_name, '')), 80);
  v_phone text := left(btrim(coalesce(p_phone, '')), 30);
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_biz text := nullif(left(btrim(coalesce(p_business, '')), 120), '');
  v_ind text := nullif(left(btrim(coalesce(p_industry, '')), 60), '');
  v_src text := nullif(left(btrim(coalesce(p_source, '')), 40), '');
  v_html text; v_text text;
begin
  if length(v_name) < 2 then
    return jsonb_build_object('ok', false, 'error', 'name');
  end if;
  if length(v_digits) < 7 or length(v_digits) > 15 or v_phone !~ '^[0-9+()\-\s.]+$' then
    return jsonb_build_object('ok', false, 'error', 'phone');
  end if;

  -- Same number again within 10 minutes: treat as already received.
  if exists (select 1 from public.sales_enquiries
              where regexp_replace(phone, '\D', '', 'g') = v_digits
                and created_at > now() - interval '10 minutes') then
    return jsonb_build_object('ok', true);
  end if;
  -- Flood guard.
  if (select count(*) from public.sales_enquiries where created_at > now() - interval '1 hour') >= 60 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;

  insert into public.sales_enquiries (name, phone, business_name, industry, source)
  values (v_name, v_phone, v_biz, v_ind, v_src);

  -- Email the team. Never let an email problem lose the enquiry.
  begin
    v_text := 'New enquiry from the website' || E'\n\n'
           || 'Name: ' || v_name || E'\n'
           || 'Contact number: ' || v_phone || E'\n'
           || 'Business: ' || coalesce(v_biz, '-') || E'\n'
           || 'Industry: ' || coalesce(v_ind, '-');
    v_html := '<div style="font-family:-apple-system,Arial,sans-serif;font-size:14px;color:#1a1a1a">'
           || '<h2 style="margin:0 0 12px">New enquiry from the website</h2><table style="border-collapse:collapse">'
           || '<tr><td style="padding:4px 16px 4px 0;color:#888">Name</td><td style="font-weight:600">' || replace(replace(replace(v_name,'&','&amp;'),'<','&lt;'),'>','&gt;') || '</td></tr>'
           || '<tr><td style="padding:4px 16px 4px 0;color:#888">Contact number</td><td style="font-weight:600">' || replace(replace(replace(v_phone,'&','&amp;'),'<','&lt;'),'>','&gt;') || '</td></tr>'
           || '<tr><td style="padding:4px 16px 4px 0;color:#888">Business</td><td style="font-weight:600">' || replace(replace(replace(coalesce(v_biz,'-'),'&','&amp;'),'<','&lt;'),'>','&gt;') || '</td></tr>'
           || '<tr><td style="padding:4px 16px 4px 0;color:#888">Industry</td><td style="font-weight:600">' || replace(replace(replace(coalesce(v_ind,'-'),'&','&amp;'),'<','&lt;'),'>','&gt;') || '</td></tr>'
           || '</table><p style="color:#888;margin-top:16px">Also listed in the web panel under Enquiries.</p></div>';
    perform public._email_send('iunisource@gmail.com', 'New enquiry: ' || coalesce(v_biz, v_name), v_html, v_text);
  exception when others then
    null;
  end;

  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.submit_enquiry(text, text, text, text, text) from public;
grant execute on function public.submit_enquiry(text, text, text, text, text) to anon, authenticated;

create or replace function public.trg_sales_enquiry_touch()
returns trigger language plpgsql as $$
begin NEW.updated_at := now(); return NEW; end $$;
drop trigger if exists trg_sales_enquiry_touch on public.sales_enquiries;
create trigger trg_sales_enquiry_touch before update on public.sales_enquiries
  for each row execute function public.trg_sales_enquiry_touch();

notify pgrst, 'reload schema';
select 'enquiries ready' as result;
