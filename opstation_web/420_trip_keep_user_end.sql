-- 420 — Server guard: a trip the salesperson ended keeps its end.
-- Older app versions could upload a trip again as "cut-off, no GPS" after the
-- salesperson had ended it (a background refresh raced the end). This refuses
-- that change on the server, so even phones still on the old app can't wipe a
-- real end any more. Reopening a trip (end cleared) still works.
-- Safe to run again.

create or replace function public.trg_trip_keep_user_end()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if OLD.ended_at is not null and NEW.ended_at is not null then
    -- Same end, but now labelled cut-off: keep the salesperson's own close.
    if OLD.close_reason = 'userEnded' and NEW.close_reason = 'cutoff'
       and abs(extract(epoch from (NEW.ended_at - OLD.ended_at))) <= 5 then
      NEW.close_reason := OLD.close_reason;
    end if;
    -- An end location never gets erased by an upload that lacks it.
    if NEW.end_lat is null and OLD.end_lat is not null then
      NEW.end_lat := OLD.end_lat;
      NEW.end_lng := OLD.end_lng;
    end if;
  end if;
  return NEW;
end $$;

-- Named to run before the cut-off end-location trigger (update 419).
drop trigger if exists trip_aa_keep_user_end on public.trips;
create trigger trip_aa_keep_user_end before update on public.trips
  for each row execute function public.trg_trip_keep_user_end();

notify pgrst, 'reload schema';
select 'trip end guard ready' as status;
