-- 309 — server clock for the login screen's "your computer's clock is wrong" check.
create or replace function public.server_now()
returns timestamptz language sql stable as $$ select now() $$;
grant execute on function public.server_now() to anon, authenticated;
