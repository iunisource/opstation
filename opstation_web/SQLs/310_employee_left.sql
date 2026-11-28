-- 310 — Employees who leave: kept in the directory only.
alter table public.hr_employees
  add column if not exists left_reason text,
  add column if not exists left_note text,
  add column if not exists left_marked_by text,
  add column if not exists left_marked_at timestamptz,
  add column if not exists left_card_uid text;

-- No attendance after the last working day — from any screen, the kiosk or an import.
create or replace function public.trg_att_block_left()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_status text; v_left date; v_name text;
begin
  select status, left_on, full_name into v_status, v_left, v_name
    from hr_employees where id = NEW.employee_id;
  if v_status = 'left' and (v_left is null or NEW.att_date > v_left) then
    raise exception '% has left the company% — attendance is not recorded after that.',
      coalesce(v_name, 'This employee'),
      coalesce(' (last working day ' || to_char(v_left, 'DD Mon YYYY') || ')', '')
      using errcode = 'P0001';
  end if;
  return NEW;
end $$;

drop trigger if exists aa_att_block_left on public.hr_attendance;
create trigger aa_att_block_left before insert or update on public.hr_attendance
  for each row execute function public.trg_att_block_left();

-- Zeeshan Ali left after 11 Sep 2026.
update public.hr_employees set status = 'left', left_on = coalesce(left_on, date '2026-09-11'), notify_punch = false
 where id = 'emp_1790841999306' and org_id = 'org_1784655141655';
