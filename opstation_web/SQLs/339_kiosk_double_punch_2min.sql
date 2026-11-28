-- 339 — Kiosk: a repeat scan within 2 minutes is ignored (not taken as Check-out)
-- kiosk_punch already ignores a repeat scan for a short window. This widens that
-- window to 2 minutes by rewriting only the window value inside the existing
-- function; nothing else in it changes. If the window can't be found, nothing
-- changes and the error shows the lines to look at.

set lock_timeout = '3s';

do $$
declare
  r record; v_def text; v_new text; v_hits text;
begin
  for r in select oid from pg_proc
            where pronamespace = 'public'::regnamespace and proname = 'kiosk_punch' loop
    v_def := pg_get_functiondef(r.oid);
    v_new := v_def;

    -- interval '30 seconds' / '45 sec' / '60 s' / '90 secs'  →  '2 minutes'
    v_new := regexp_replace(v_new,
      $re$interval\s*'\s*(?:[1-9][0-9]|1[01][0-9])\s*(?:s|sec|secs|second|seconds)\s*'$re$,
      $r$interval '2 minutes'$r$, 'gi');
    -- interval '1 minute' / '1 min'  →  '2 minutes'
    v_new := regexp_replace(v_new,
      $re$interval\s*'\s*1\s*(?:min|mins|minute|minutes)\s*'$re$,
      $r$interval '2 minutes'$r$, 'gi');
    -- make_interval(secs => 30)  →  make_interval(secs => 120)
    v_new := regexp_replace(v_new,
      $re$make_interval\s*\(\s*secs\s*=>\s*(?:[1-9][0-9]|1[01][0-9])\s*\)$re$,
      'make_interval(secs => 120)', 'gi');
    -- extract(epoch from (...)) < 30   →  < 120   (seconds compared as a number)
    v_new := regexp_replace(v_new,
      $re$(epoch\s+from[^;/]{0,120}?\)\s*\)?\s*<=?\s*)(?:[1-9][0-9]|1[01][0-9])(?![0-9])$re$,
      '\1120', 'gi');
    -- user-facing wording
    v_new := regexp_replace(v_new, $re$(try again in )(a minute|[0-9]+ seconds)$re$, '\12 minutes', 'gi');

    if v_new = v_def then
      select string_agg(l, E'\n') into v_hits
        from regexp_split_to_table(v_def, E'\n') l
       where l ~* '(interval|epoch|seconds|minute|now\(\))';
      raise exception E'No repeat-scan window found in kiosk_punch — nothing changed. Lines to check:\n%', v_hits;
    end if;

    execute v_new;
    raise notice 'kiosk_punch updated: repeat-scan window is now 2 minutes';
  end loop;
end $$;

reset lock_timeout;

-- Check: should show '2 minutes' (or 120) where the window is.
select l as kiosk_punch_window_lines
  from pg_proc p, regexp_split_to_table(pg_get_functiondef(p.oid), E'\n') l
 where p.proname = 'kiosk_punch' and l ~* '(2 minutes|120)';
