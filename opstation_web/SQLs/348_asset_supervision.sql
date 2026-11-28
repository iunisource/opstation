-- 348 — Asset supervision (toggle: org.asset_supervise_flow,
--       supervisors: org.asset_supervisor_users).
-- Every new asset, and every edit to an existing one, goes to the picked
-- supervisors for a check. They Supervise it or Reject it with a reason (back
-- to whoever last changed it). Non-blocking: the asset works as normal while
-- it waits. The server records what changed (old → new) since the last check.
-- Notifications: asset_supervise, asset_supervise_rejected, asset_supervised.
-- Requires 296 (notify_event). Safe to run again.

alter table public.assets
  add column if not exists supervised_at       timestamptz,
  add column if not exists supervised_by       text,
  add column if not exists supervised_by_name  text,
  add column if not exists rejected_at         timestamptz,
  add column if not exists rejected_by         text,
  add column if not exists rejected_by_name    text,
  add column if not exists reject_reason       text,
  add column if not exists sup_reason          text,   -- created | edited | resubmitted
  add column if not exists sup_diff            jsonb,  -- {field: {"from": .., "to": ..}} since last check
  add column if not exists sup_changed_by      text,   -- users.id of the last person who changed it
  add column if not exists sup_changed_by_name text,
  add column if not exists sup_changed_at      timestamptz;

-- Everything that exists today counts as already checked.
update public.assets
   set supervised_at = coalesce(created_at, now()), supervised_by_name = 'Auto (existing asset)'
 where supervised_at is null and rejected_at is null and sup_reason is null;

create index if not exists idx_assets_sup_pending
  on public.assets(org_id) where supervised_at is null;

-- ── BEFORE trigger: stamp changes, reset to pending, guard the supervise action
create or replace function public.trg_asset_supervision()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_on boolean;
  v_uid text; v_name text;
  v_sups text[];
  n jsonb; o jsonb; f text; ov text; nv text;
  d jsonb;
  changed boolean := false;
  watched text[] := array['asset_code', 'name', 'description', 'category_id', 'status', 'condition',
                          'branch_id', 'location_text', 'assigned_to', 'serial_no', 'model',
                          'manufacturer', 'supplier_id', 'purchase_cost', 'purchase_date',
                          'warranty_expiry', 'notes'];
begin
  v_on := public._cfg_on(NEW.org_id, 'org.asset_supervise_flow');

  select u.id, u.name into v_uid, v_name
    from public.users u
   where u.org_id = NEW.org_id
     and (u.account_id = public.current_account_id()
          or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
   limit 1;

  select coalesce(array_agg(btrim(x)), '{}') into v_sups
    from unnest(string_to_array(coalesce(
           (select value from public.app_config
             where org_id = NEW.org_id and key = 'org.asset_supervisor_users' limit 1), ''), ',')) x
   where btrim(x) <> '';

  if TG_OP = 'INSERT' then
    if v_on then
      NEW.supervised_at := null; NEW.supervised_by := null; NEW.supervised_by_name := null;
      NEW.rejected_at := null; NEW.rejected_by := null; NEW.rejected_by_name := null; NEW.reject_reason := null;
      NEW.sup_reason := 'created';
      NEW.sup_diff := null;
    else
      NEW.supervised_at := coalesce(NEW.supervised_at, now());
      NEW.supervised_by_name := coalesce(NEW.supervised_by_name, 'Auto (supervision off)');
    end if;
    NEW.sup_changed_by := v_uid;
    NEW.sup_changed_by_name := coalesce(v_name, 'System');
    NEW.sup_changed_at := now();
    return NEW;
  end if;

  -- UPDATE ─────────────────────────────────────────────────────────────────
  -- 1) Supervise / reject: only the picked supervisors (signed-in users).
  if (NEW.supervised_at is not null and OLD.supervised_at is null)
     or (NEW.rejected_at is not null and NEW.rejected_at is distinct from OLD.rejected_at) then
    if auth.uid() is not null and (v_uid is null or not (v_uid = any (v_sups))) then
      raise exception 'Only asset supervisors (Admin Settings) can supervise or reject assets.';
    end if;
    if NEW.supervised_at is not null and OLD.supervised_at is null then
      NEW.supervised_by := coalesce(v_uid, NEW.supervised_by);
      NEW.supervised_by_name := coalesce(v_name, NEW.supervised_by_name);
      NEW.rejected_at := null; NEW.rejected_by := null; NEW.rejected_by_name := null; NEW.reject_reason := null;
      NEW.sup_diff := null;
    else
      NEW.rejected_by := coalesce(v_uid, NEW.rejected_by);
      NEW.rejected_by_name := coalesce(v_name, NEW.rejected_by_name);
      NEW.supervised_at := null;
    end if;
    return NEW;
  end if;

  if not v_on then return NEW; end if;

  -- 2) A real edit: collect what changed (keep the ORIGINAL "from" while pending).
  n := to_jsonb(NEW); o := to_jsonb(OLD);
  d := case when OLD.supervised_at is null then coalesce(OLD.sup_diff, '{}'::jsonb) else '{}'::jsonb end;
  foreach f in array watched loop
    ov := nullif(btrim(o ->> f), '');
    nv := nullif(btrim(n ->> f), '');
    continue when ov is not distinct from nv;
    if ov ~ '^-?[0-9]+(\.[0-9]+)?$' and nv ~ '^-?[0-9]+(\.[0-9]+)?$' and ov::numeric = nv::numeric then
      continue;
    end if;
    changed := true;
    if d ? f then
      d := jsonb_set(d, array[f], jsonb_build_object('from', d -> f -> 'from', 'to', nv));
      -- edited back to what the supervisor last saw: drop it
      if (d -> f ->> 'from') is not distinct from nv then d := d - f; end if;
    else
      d := d || jsonb_build_object(f, jsonb_build_object('from', ov, 'to', nv));
    end if;
  end loop;

  -- 3) Resend after a rejection (with or without further changes).
  if OLD.rejected_at is not null and NEW.rejected_at is null and NEW.supervised_at is null then
    NEW.sup_reason := 'resubmitted';
    NEW.sup_diff := case when d = '{}'::jsonb then OLD.sup_diff else d end;
    NEW.sup_changed_by := coalesce(v_uid, NEW.sup_changed_by);
    NEW.sup_changed_by_name := coalesce(v_name, NEW.sup_changed_by_name);
    NEW.sup_changed_at := now();
    return NEW;
  end if;

  if not changed then return NEW; end if;

  NEW.sup_diff := case when d = '{}'::jsonb then null else d end;
  if OLD.supervised_at is not null then
    NEW.sup_reason := 'edited';
  elsif OLD.rejected_at is not null then
    NEW.sup_reason := 'resubmitted';
  else
    NEW.sup_reason := coalesce(OLD.sup_reason, 'edited'); -- a still-pending new asset stays "created"
  end if;
  NEW.supervised_at := null; NEW.supervised_by := null; NEW.supervised_by_name := null;
  NEW.rejected_at := null; NEW.rejected_by := null; NEW.rejected_by_name := null; NEW.reject_reason := null;
  NEW.sup_changed_by := coalesce(v_uid, NEW.sup_changed_by);
  NEW.sup_changed_by_name := coalesce(v_name, 'System');
  NEW.sup_changed_at := now();
  return NEW;
end $$;

drop trigger if exists aa_asset_supervision on public.assets;
create trigger aa_asset_supervision before insert or update on public.assets
  for each row execute function public.trg_asset_supervision();

-- ── AFTER trigger: notifications (never blocks a save)
create or replace function public.trg_asset_supervision_notify()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_label text;
  v_path text;
  v_what text;
  was_pending boolean;
begin
  begin
    if not public._cfg_on(NEW.org_id, 'org.asset_supervise_flow') then return NEW; end if;
    v_label := coalesce(NEW.asset_code || ' · ', '') || coalesce(NEW.name, 'Asset');
    v_path := '/assets?focus=' || NEW.id;
    was_pending := TG_OP = 'UPDATE' and OLD.supervised_at is null and OLD.rejected_at is null;

    -- Now waiting for a check (new, edited after a check, or resent after a reject)
    if NEW.supervised_at is null and NEW.rejected_at is null and not was_pending then
      v_what := case NEW.sup_reason when 'created' then 'New asset'
                                    when 'resubmitted' then 'Resent after rejection'
                                    else 'Edited' end;
      if NEW.sup_diff is not null and NEW.sup_diff <> '{}'::jsonb then
        select v_what || ': ' || string_agg(initcap(replace(replace(k, '_id', ''), '_', ' ')), ', ')
          into v_what from jsonb_object_keys(NEW.sup_diff) k;
      end if;
      perform public.notify_event(NEW.org_id, 'asset_supervise', NEW.branch_id, NEW.sup_changed_by,
        'Asset needs supervision',
        v_label || ' — ' || v_what || coalesce(' by ' || nullif(NEW.sup_changed_by_name, ''), ''),
        v_path);
    end if;

    if TG_OP = 'UPDATE' then
      if NEW.rejected_at is not null and NEW.rejected_at is distinct from OLD.rejected_at then
        perform public.notify_event(NEW.org_id, 'asset_supervise_rejected', NEW.branch_id, NEW.sup_changed_by,
          'Asset rejected by supervisor',
          v_label || coalesce(' — rejected by ' || nullif(NEW.rejected_by_name, ''), '')
                  || coalesce(': ' || nullif(NEW.reject_reason, ''), ''),
          v_path);
      end if;
      if NEW.supervised_at is not null and OLD.supervised_at is null then
        perform public.notify_event(NEW.org_id, 'asset_supervised', NEW.branch_id, NEW.sup_changed_by,
          'Asset supervised',
          v_label || coalesce(' — supervised by ' || nullif(NEW.supervised_by_name, ''), ''),
          v_path);
      end if;
    end if;
  exception when others then
    null;
  end;
  return NEW;
end $$;

drop trigger if exists zz_asset_supervision_notify on public.assets;
create trigger zz_asset_supervision_notify after insert or update on public.assets
  for each row execute function public.trg_asset_supervision_notify();

-- Live pendency counter: stream assets changes.
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'assets') then
    alter publication supabase_realtime add table public.assets;
  end if;
end $$;
